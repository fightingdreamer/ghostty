/// Split represents a surface split where two surfaces are shown side-by-side
/// within the same window either vertically or horizontally.
const Split = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

/// The split orientation.
pub const Orientation = enum {
    horizontal,
    vertical,

    pub fn fromDirection(direction: input.SplitDirection) Orientation {
        return switch (direction) {
            .right => .horizontal,
            .down => .vertical,
        };
    }

    pub fn fromResizeDirection(direction: input.SplitResizeDirection) Orientation {
        return switch (direction) {
            .up, .down => .vertical,
            .left, .right => .horizontal,
        };
    }
};

/// Our actual GtkPaned widget
paned: *c.GtkPaned,

/// The container for this split panel.
container: Surface.Container,

/// The orientation of this split panel.
orientation: Orientation,

/// The elements of this split panel.
top_left: Surface.Container.Elem,
bottom_right: Surface.Container.Elem,

/// Create a new split panel with the given sibling surface in the given
/// direction. The direction is where the new surface will be initialized.
///
/// The sibling surface can be in a split already or it can be within a
/// tab. This properly handles updating the surface container so that
/// it represents the new split.
pub fn create(
    alloc: Allocator,
    sibling: *Surface,
    direction: input.SplitDirection,
) !*Split {
    var split = try alloc.create(Split);
    errdefer alloc.destroy(split);
    try split.init(sibling, direction);
    return split;
}

pub fn init(
    self: *Split,
    sibling: *Surface,
    direction: input.SplitDirection,
) !void {
    // Create the new child surface for the other direction.
    const alloc = sibling.app.core_app.alloc;
    var surface = try Surface.create(alloc, sibling.app, .{
        .parent = &sibling.core_surface,
    });
    errdefer surface.destroy(alloc);

    // Create the actual GTKPaned, attach the proper children.
    const orientation: c_uint = switch (direction) {
        .right => c.GTK_ORIENTATION_HORIZONTAL,
        .down => c.GTK_ORIENTATION_VERTICAL,
    };
    const paned = c.gtk_paned_new(orientation);
    errdefer c.g_object_unref(paned);

    // Keep a long-lived reference, which we unref in destroy.
    _ = c.g_object_ref(paned);

    // Update all of our containers to point to the right place.
    // The split has to point to where the sibling pointed to because
    // we're inheriting its parent. The sibling points to its location
    // in the split, and the surface points to the other location.
    const container = sibling.container;
    sibling.container = .{ .split_tl = &self.top_left };
    surface.container = .{ .split_br = &self.bottom_right };

    self.* = .{
        .paned = @ptrCast(paned),
        .container = container,
        .top_left = .{ .surface = sibling },
        .bottom_right = .{ .surface = surface },
        .orientation = Orientation.fromDirection(direction),
    };

    // Replace the previous containers element with our split.
    // This allows a non-split to become a split, a split to
    // become a nested split, etc.
    container.replace(.{ .split = self });

    // Update our children so that our GL area is properly
    // added to the paned.
    self.updateChildren();

    // The new surface should always grab focus
    surface.grabFocus();
}

pub fn destroy(self: *Split, alloc: Allocator) void {
    self.top_left.deinit(alloc);
    self.bottom_right.deinit(alloc);

    // Clean up our GTK reference. This will trigger all the destroy callbacks
    // that are necessary for the surfaces to clean up.
    c.g_object_unref(self.paned);

    alloc.destroy(self);
}

/// Remove the top left child.
pub fn removeTopLeft(self: *Split) void {
    self.removeChild(self.top_left, self.bottom_right);
}

/// Remove the top left child.
pub fn removeBottomRight(self: *Split) void {
    self.removeChild(self.bottom_right, self.top_left);
}

fn removeChild(
    self: *Split,
    remove: Surface.Container.Elem,
    keep: Surface.Container.Elem,
) void {
    const window = self.container.window() orelse return;
    const alloc = window.app.core_app.alloc;

    // Remove our children since we are going to no longer be
    // a split anyways. This prevents widgets with multiple parents.
    self.removeChildren();

    // Our container must become whatever our top left is
    self.container.replace(keep);

    // Grab focus of the left-over side
    keep.grabFocus();

    // When a child is removed we are no longer a split, so destroy ourself
    remove.deinit(alloc);
    alloc.destroy(self);
}

/// Move the divider in the given direction by the given amount.
pub fn moveDivider(self: *Split, direction: input.SplitResizeDirection, amount: u16) void {
    const pos = c.gtk_paned_get_position(self.paned);
    const new = switch (direction) {
        .up, .left => pos - amount,
        .down, .right => pos + amount,
    };

    c.gtk_paned_set_position(self.paned, new);
}

/// Equalize the splits in this split panel. Each split is equalized based on
/// its weight, i.e. the number of Surfaces it contains.
///
/// It works recursively by equalizing the children of each split.
///
/// It returns this split's weight.
pub fn equalize(self: *Split) f64 {
    // Calculate weights of top_left/bottom_right
    const top_left_weight = self.top_left.equalize();
    const bottom_right_weight = self.bottom_right.equalize();
    const weight = top_left_weight + bottom_right_weight;

    // Ratio of top_left weight to overall weight, which gives the split ratio
    const ratio = top_left_weight / weight;

    // Convert split ratio into new position for divider
    c.gtk_paned_set_position(self.paned, @intFromFloat(self.maxPosition() * ratio));

    return weight;
}

// maxPosition returns the maximum position of the GtkPaned, which is the
// "max-position" attribute.
fn maxPosition(self: *Split) f64 {
    var value: c.GValue = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&value);

    _ = c.g_value_init(&value, c.G_TYPE_INT);
    c.g_object_get_property(
        @ptrCast(@alignCast(self.paned)),
        "max-position",
        &value,
    );

    return @floatFromInt(c.g_value_get_int(&value));
}

// This replaces the element at the given pointer with a new element.
// The ptr must be either top_left or bottom_right (asserted in debug).
// The memory of the old element must be freed or otherwise handled by
// the caller.
pub fn replace(
    self: *Split,
    ptr: *Surface.Container.Elem,
    new: Surface.Container.Elem,
) void {
    // We can write our element directly. There's nothing special.
    assert(&self.top_left == ptr or &self.bottom_right == ptr);
    ptr.* = new;

    // Update our paned children. This will reset the divider
    // position but we want to keep it in place so save and restore it.
    const pos = c.gtk_paned_get_position(self.paned);
    defer c.gtk_paned_set_position(self.paned, pos);
    self.updateChildren();
}

// grabFocus grabs the focus of the top-left element.
pub fn grabFocus(self: *Split) void {
    self.top_left.grabFocus();
}

/// Update the paned children to represent the current state.
/// This should be called anytime the top/left or bottom/right
/// element is changed.
fn updateChildren(self: *const Split) void {
    // We have to set both to null. If we overwrite the pane with
    // the same value, then GTK bugs out (the GL area unrealizes
    // and never rerealizes).
    self.removeChildren();

    // Set our current children
    c.gtk_paned_set_start_child(
        @ptrCast(self.paned),
        self.top_left.widget(),
    );
    c.gtk_paned_set_end_child(
        @ptrCast(self.paned),
        self.bottom_right.widget(),
    );
}

/// A mapping of direction to the element (if any) in that direction.
pub const DirectionMap = std.EnumMap(
    input.SplitFocusDirection,
    ?*Surface,
);

pub const Side = enum { top_left, bottom_right };

/// Returns the map that can be used to determine elements in various
/// directions (primarily for gotoSplit).
pub fn directionMap(self: *const Split, from: Side) DirectionMap {
    var result = DirectionMap.initFull(null);

    if (self.directionPrevious(from)) |prev| {
        result.put(.previous, prev);

        // This behavior matches the behavior of macOS at the time of writing
        // this. There is an open issue (#524) to make this depend on the
        // actual physical location of the current split.
        result.put(.top, prev);
        result.put(.left, prev);
    }

    if (self.directionNext(from)) |next| {
        result.put(.next, next);
        result.put(.bottom, next);
        result.put(.right, next);
    }

    return result;
}

fn directionPrevious(self: *const Split, from: Side) ?*Surface {
    switch (from) {
        // From the bottom right, our previous is the deepest surface
        // in the top-left of our own split.
        .bottom_right => return self.top_left.deepestSurface(.bottom_right),

        // From the top left its more complicated. It is the de
        .top_left => {
            // If we have no parent split then there can be no previous.
            const parent = self.container.split() orelse return null;
            const side = self.container.splitSide() orelse return null;

            // The previous value is the previous of the side that we are.
            return switch (side) {
                .top_left => parent.directionPrevious(.top_left),
                .bottom_right => parent.directionPrevious(.bottom_right),
            };
        },
    }
}

fn directionNext(self: *const Split, from: Side) ?*Surface {
    switch (from) {
        // From the top left, our next is the earliest surface in the
        // top-left direction of the bottom-right side of our split. Fun!
        .top_left => return self.bottom_right.deepestSurface(.top_left),

        // From the bottom right is more compliated. It is the deepest
        // (last) surface in the
        .bottom_right => {
            // If we have no parent split then there can be no next.
            const parent = self.container.split() orelse return null;
            const side = self.container.splitSide() orelse return null;

            // The previous value is the previous of the side that we are.
            return switch (side) {
                .top_left => parent.directionNext(.top_left),
                .bottom_right => parent.directionNext(.bottom_right),
            };
        },
    }
}

fn removeChildren(self: *const Split) void {
    c.gtk_paned_set_start_child(@ptrCast(self.paned), null);
    c.gtk_paned_set_end_child(@ptrCast(self.paned), null);
}
