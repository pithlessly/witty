const c = @cImport({
    @cInclude("SDL.h");
});

const Frame = @import("witty").ttyrec.Frame;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

fn float(x: anytype) f64 {
    return @intToFloat(f64, x);
}

const tick_radius = 1;

pub fn draw(
    pb: *State,
    renderer: *c.SDL_Renderer,
    w: u31,
    h: u31,
    frames: []const Frame,
) !void {
    const padding = 10;
    const bar_width = w -| (2 * padding);
    if (bar_width == 0) return;
    const bar_height = 10;
    const bar_x = 0 + padding;
    const bar_y = h -| (padding + bar_height);
    if (bar_y == 0) return;
    // draw progress bar rectangle
    _ = c.SDL_SetRenderDrawColor(renderer, 0x40, 0x40, 0x40, 0xFF);
    _ = c.SDL_RenderFillRect(renderer, &c.SDL_Rect{
        .x = @intCast(c_int, bar_x),
        .y = @intCast(c_int, bar_y),
        .w = @intCast(c_int, bar_width),
        .h = @intCast(c_int, bar_height),
    });

    // draw tick ranges
    if (frames.len == 0) return;
    _ = c.SDL_SetRenderDrawColor(renderer, 0xA0, 0xA0, 0xA0, 0xFF);
    const iterator = try pb.updateWithFrames(bar_width, frames);
    iterator.iterate(struct {
        renderer: *c.SDL_Renderer,
        padding: c_int,
        bar_y: c_int,
        bar_height: c_int,
        fn call(s: @This(), range: PixelRange) void {
            _ = c.SDL_RenderFillRect(s.renderer, &c.SDL_Rect{
                .x = s.padding + range.start,
                .y = s.bar_y,
                .w = range.end - range.start,
                .h = s.bar_height,
            });
        }
    }{ .renderer = renderer, .padding = padding, .bar_y = bar_y, .bar_height = bar_height });
}

const FrameBranch = struct {
    const Ref = packed struct {
        kind: enum(u1) { frame, branch },
        index: u31,
    };
    lhs: Ref,
    rhs: Ref,
    separation: u64,
};

pub const State = struct {
    branches: std.ArrayList(FrameBranch),
    root: ?FrameBranch.Ref,

    pub fn init(alloc: Allocator) State {
        return .{
            .branches = std.ArrayList(FrameBranch).init(alloc),
            .root = null,
        };
    }

    pub fn deinit(self: State) void {
        self.branches.deinit();
    }

    fn updateWithFrames(self: *State, bar_width: u31, frames: []const Frame) !PixelRangeIterator {
        assert(frames.len > 0);
        const min_time = frames[0].timestamp;
        const max_time = frames[frames.len - 1].timestamp;
        const time_range = float(std.math.max(1, max_time - min_time));

        // if the tree is empty, replace it with a single leaf
        // pointing to the first frame
        if (self.root == null) {
            self.root = FrameBranch.Ref{ .kind = .frame, .index = 0 };
        }

        // each frame is a leaf of the tree, and a binary tree
        // with N+1 leaves always has N branches
        const known_frames = self.branches.items.len + 1;
        assert(known_frames <= frames.len);

        // if there were any *more* frames added beyond the first one,
        // we need to extend the three to account for them, one per branch
        if (frames.len > known_frames) {
            try self.branches.ensureUnusedCapacity(frames.len - known_frames);
            var idx = known_frames;
            while (idx < frames.len) : (idx += 1) {
                const separation = frames[idx].timestamp - frames[idx - 1].timestamp;
                self.branches.appendAssumeCapacity(addFrameToSubtree(
                    self.branches.items,
                    &self.root.?,
                    separation,
                    @intCast(u31, idx),
                ));
            }
        }

        return PixelRangeIterator{
            .branches = self.branches.items,
            .frames = frames,
            .root = self.root.?,
            .min_time = float(min_time),
            .px_per_us = float(bar_width) / time_range,
        };
    }

    fn addFrameToSubtree(
        branches: []FrameBranch,
        root: *FrameBranch.Ref,
        separation: u64,
        new_frame_idx: u31,
    ) FrameBranch {
        if (root.kind == .branch and
            separation < branches[root.index].separation)
        {
            // recursively add the new frame to the right child
            const sub_root = &branches[root.index].rhs;
            return addFrameToSubtree(branches, sub_root, separation, new_frame_idx);
        } else {
            // make the newly created branch into the root of this subtree.
            // the current subtree is moved into the left child of the branch,
            // and the right child of the branch is a leaf for the new frame
            const new_branch_idx = @intCast(u31, branches.len);
            defer root.* = .{ .kind = .branch, .index = new_branch_idx };
            return .{
                .lhs = root.*,
                .rhs = .{ .kind = .frame, .index = new_frame_idx },
                .separation = separation,
            };
        }
    }
};

const PixelRange = struct {
    start: i32,
    end: i32,

    fn fromTimestamps(t1: u64, t2: u64, min_time: f64, px_per_us: f64) PixelRange {
        const px1 = @round((float(t1) - min_time) * px_per_us);
        const px2 = @round((float(t2) - min_time) * px_per_us);
        return .{
            .start = @floatToInt(i32, px1) - tick_radius,
            .end = @floatToInt(i32, px2) + tick_radius,
        };
    }
};

const PixelRangeIterator = struct {
    branches: []const FrameBranch,
    frames: []const Frame,
    root: FrameBranch.Ref,
    min_time: f64,
    px_per_us: f64,

    fn iterate(self: PixelRangeIterator, callback: anytype) void {
        self.visitNode(self.root, callback);
    }

    fn visitNode(self: PixelRangeIterator, node: FrameBranch.Ref, callback: anytype) void {
        switch (node.kind) {
            .frame => {
                const ts = self.frames[node.index].timestamp;
                callback.call(PixelRange.fromTimestamps(ts, ts, self.min_time, self.px_per_us));
            },
            .branch => {
                const branch = self.branches[node.index];
                if (float(branch.separation) * self.px_per_us < 2 * tick_radius) {
                    callback.call(PixelRange.fromTimestamps(
                        self.frames[branchStartFrame(branch, self.branches)].timestamp,
                        self.frames[branchEndFrame(branch, self.branches)].timestamp,
                        self.min_time,
                        self.px_per_us,
                    ));
                } else {
                    visitNode(self, branch.lhs, callback);
                    visitNode(self, branch.rhs, callback);
                }
            },
        }
    }

    fn branchStartFrame(branch: FrameBranch, branches: []const FrameBranch) u31 {
        var b = branch;
        while (true) switch (b.lhs.kind) {
            .frame => return b.lhs.index,
            .branch => b = branches[b.lhs.index],
        };
    }

    fn branchEndFrame(branch: FrameBranch, branches: []const FrameBranch) u31 {
        var b = branch;
        while (true) switch (b.rhs.kind) {
            .frame => return b.rhs.index,
            .branch => b = branches[b.rhs.index],
        };
    }
};
