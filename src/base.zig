//! All base types and functions for zig-cats
const std = @import("std");
const testing = std.testing;
const testu = @import("test_utils.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// pub usingnamespace @import("base_types.zig");

/// A single-argument type function for type constructor
pub const TCtor = *const fn (comptime type) type;

pub fn GetPointerChild(comptime P: type) type {
    if (@typeInfo(P) != .Pointer) {
        @compileError("The type P must be a Pointer type!");
    }
    return std.meta.Child(P);
}

pub fn MapFnInType(comptime MapFn: type) type {
    const _MapFn = if (@typeInfo(MapFn) == .Pointer) std.meta.Child(MapFn) else MapFn;
    const info = @typeInfo(_MapFn);
    const len = info.Fn.params.len;

    if (len != 1) {
        @compileError("The map function must has only one parameter!");
    }

    return info.Fn.params[0].type.?;
}

pub fn MapFnRetType(comptime MapFn: type) type {
    const _MapFn = if (@typeInfo(MapFn) == .Pointer) std.meta.Child(MapFn) else MapFn;
    const R = @typeInfo(_MapFn).Fn.return_type.?;

    if (R == noreturn) {
        @compileError("The return type of map function must not be noreturn!");
    }
    return R;
}

pub fn MapLamInType(comptime MapLam: type) type {
    const info = @typeInfo(MapLam);
    if (info != .Struct) {
        @compileError("The map lambda must be a struct!");
    }

    const mapFnInfo = @typeInfo(@TypeOf(MapLam.call));
    const len = mapFnInfo.Fn.params.len;

    if (len != 2) {
        @compileError("The call function of map lambda must have only two parameters!");
    }
    if (mapFnInfo.Fn.params[0].type.? != *MapLam and mapFnInfo.Fn.params[0].type.? != *const MapLam) {
        @compileError("The first parameter of call function must be a pointer of MapLam!");
    }

    return mapFnInfo.Fn.params[1].type.?;
}

pub fn MapLamRetType(comptime MapLam: type) type {
    const info = @typeInfo(MapLam);
    if (info != .Struct) {
        @compileError("The map lambda must be a struct!");
    }

    const mapFnInfo = @typeInfo(@TypeOf(MapLam.call));
    const R = mapFnInfo.Fn.return_type.?;

    if (R == noreturn) {
        @compileError("The return type of call function must not be noreturn!");
    }
    return R;
}

pub fn AnyMapFn(a: anytype, b: anytype) type {
    return fn (@TypeOf(a)) @TypeOf(b);
}

/// The kind of map function for new a translated value or inplace replaced by
/// translated value.
pub const MapFnKind = enum {
    /// Need new a value for translated value, the caller should to free new
    /// value.
    NewValMap,
    /// Need new a value for translated value, the caller should to free new
    /// value.
    /// The input value of map function is a reference.
    /// The fa paramerter of fmap function is also a reference.
    NewValMapRef,
    /// Just inplace replace with translated value, the bitsize of translated
    /// value must equal bitsize of origin value.
    InplaceMap,
    /// Just inplace replace with translated value, the bitsize of translated
    /// value must equal bitsize of origin value.
    /// The input value of map function is a reference.
    /// The fa paramerter of fmap function is also a reference.
    InplaceMapRef,
};

pub fn isInplaceMap(comptime K: MapFnKind) bool {
    return K == .InplaceMap or K == .InplaceMapRef;
}

pub fn isMapRef(comptime K: MapFnKind) bool {
    return K == .NewValMapRef or K == .InplaceMapRef;
}

/// The mode of fmap is used to indicate whether the map function has a self
/// parameter.
pub const FMapMode = enum {
    /// The map function has only a input parameter.
    NormalMap,
    /// The map function is a lambda struct that has a map function with a
    /// self parameter.
    LambdaMap,
};

pub const RainbowColor = enum {
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Indigo,
    Violet,
};

/// A identity function as unit of endofunctions
fn identity(a: anytype) @TypeOf(a) {
    return a;
}

pub fn getIdentityFn(comptime A: type) *const fn (A) A {
    return &struct {
        fn id(a: A) A {
            return a;
        }
    }.id;
}

pub fn IdentityLamType(comptime T: type) type {
    return struct {
        lam_ctx: void = {},

        const Self = @This();
        fn call(self: Self, val: T) T {
            _ = self;
            return val;
        }
    };
}

pub fn getIdentityLam(comptime A: type) IdentityLamType(A) {
    return IdentityLamType(A){};
}

pub const AnyFnType = fn (usize) usize;
pub const AnyFnPtr = *const AnyFnType;

pub fn AnyLamFromFn(
    comptime A: type,
    comptime B: type,
    comptime lam_fn: *const fn (*anyopaque, A) B,
) type {
    return struct {
        lam_ctx: *anyopaque,
        const Self = @This();
        pub fn call(self: Self, a: A) B {
            return lam_fn(self.lam_ctx, a);
        }
    };
}

fn ComposedTwoFn(comptime A: type, comptime B: type, comptime C: type) type {
    return struct {
        first_fn: *const fn (A) B,
        second_fn: *const fn (B) C,
        const SelfComp = @This();
        fn call(selfComp: SelfComp, a: A) C {
            return selfComp.second_fn(selfComp.first_fn(a));
        }
    };
}

fn ComposedManyFn(
    comptime N: comptime_int,
    comptime TS: [N]type,
) type {
    if (N < 4) {
        @compileError("Too less types for ComposedManyFn");
    }
    return struct {
        fns_array: ArrayList(AnyFnPtr),

        const Self = @This();
        const N_FNS = N - 1;
        pub fn FnsTypes() [N_FNS]type {
            comptime var fn_types: [N_FNS]type = undefined;
            inline for (TS[0..N_FNS], 0..) |T, i| {
                fn_types[i] = *const fn (T) TS[i + 1];
            }
            return fn_types;
        }

        pub fn call(self: Self, a: TS[0]) TS[N - 1] {
            assert(N_FNS == self.fns_array.items.len);
            var results: std.meta.Tuple(TS[0..]) = undefined;
            results[0] = a;
            comptime var i = 0;
            inline while (i < N - 1) : (i += 1) {
                const fn_ptr = @as(FnsTypes()[i], @ptrCast(self.fns_array.items[i]));
                results[i + 1] = fn_ptr(results[i]);
            }
            return results[N - 1];
        }
    };
}

// ComposableFn :: [a -> b, b -> c, c-> d ... e -> f] -> (a -> f)

const IOType = struct {
    inputType: type,
    outputType: type,
};

pub fn extraIO(comptime fun: type) IOType {
    const info = @typeInfo(fun);
    switch (info) {
        .@"fn" => |f| {
            const len = f.params.len;
            if (len != 1) {
                @compileError("The map function must has only one parameter!");
            }
            const R = f.return_type.?;
            if (R == noreturn) {
                @compileError("The return type of map function must not be noreturn!");
            }
            return .{
                .inputType = f.params[0].type.?,
                .outputType = R,
            };
        },
        else => @compileError("Not a fun!"),
    }
}

pub fn MCF(comptime fs: []const type) type {
    switch (fs.len) {
        0 => @compileError("Invalid input"),
        1 => return fs[0],
        else => for (0..fs.len - 1) |i| {
            const cio = extraIO(fs[i]);
            const nio = extraIO(fs[i + 1]);
            if (cio.outputType != nio.inputType) {
                @compileError(std.fmt.comptimePrint("Function not match!, idx {d} output: {any}, idx {d} input: {any} ", .{ i, cio.outputType, i + 1, nio.inputType }));
            }
            if (i == fs.len - 2) {
                const rcio = extraIO(fs[0]);
                const rnio = extraIO(fs[fs.len - 1]);
                return fn (rcio.inputType) rnio.outputType;
            }
        },
    }
}

pub fn mcomposefn(fa: anytype, fb: anytype) (MCF(&.{ @TypeOf(fa), @TypeOf(fb) })) {
    const cio = extraIO(@TypeOf(fa));
    const nio = extraIO(@TypeOf(fb));

    const Tmp = struct {
        pub fn fun(a: cio.inputType) nio.outputType {
            return fb(fa(a));
        }
    };
    return Tmp.fun;
}

test "MCF" {
    const v1 = mcomposefn(add_fun1, add_fun2);
    const v2 = mcomposefn(v1, v1);
    const v3 = mcomposefn(v2, mcomposefn(v1, v2));
    const v4 = mcomposefn(v1, v3);
    std.debug.print("\n{any}\n", .{v4(0)});
}

pub fn extraStructAllTypes(comptime args: anytype) []const type {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    switch (args_type_info) {
        .@"struct" => {
            const fields = args_type_info.Struct.fields;
            // fields less 100!!
            var tmp: [100]type = undefined;
            for (0..fields.len) |i| {
                tmp[i] = fields[i].type;
            }
            return tmp[0..fields.len];
        },
        else => @compileError("input error, need struct"),
    }
}

// const FunType = struct {
//     funType: []type,
// };

// const FunPtr = struct {
//     funPtr: []*const anyopaque,
// };

pub fn MyFun1(comptime fts: []const type, fps: []*const anyopaque) type {
    return struct {
        const InputType = extraIO(fts[0]).inputType;
        fn go(comptime i: usize, input: InputType) extraIO(fts[i]).outputType {
            const fti = fts[i];
            const sf: *const fti = @ptrCast(fps[i]);
            if (i == 0) {
                return @call(.auto, sf, .{input});
            } else {
                return @call(.auto, sf, .{go(i - 1, input)});
            }
        }

        pub fn call(input: InputType) extraIO(fts[fts.len - 1]).outputType {
            return go(fts.len - 1, input);
        }
    };
}

pub fn mcomposefns(args: anytype) (MCF(extraStructAllTypes(args))) {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    switch (args_type_info) {
        .Struct => {
            const fields = args_type_info.Struct.fields;
            const Tmp = struct {
                const InputType = extraIO(fields[0].type).inputType;
                pub fn fun(comptime i: usize, input: InputType) extraIO(fields[i].type).outputType {
                    const sf = @field(args, fields[i].name);
                    if (i == 0) {
                        return @call(.auto, sf, .{input});
                    } else {
                        return @call(.auto, sf, .{fun(i - 1, input)});
                    }
                }
                const OutputType = extraIO(fields[fields.len - 1].type).outputType;
                pub fn fun1(input: InputType) OutputType {
                    return fun(fields.len - 1, input);
                }
            };
            return Tmp.fun1;
        },
        else => @compileError("input error, need struct"),
    }
}

pub fn MyMaybe(T: type) type {
    return union(enum) {
        Nothing: void,
        Just: T,

        const elem = T;

        pub fn fmap(fa: MyMaybe(T), f: anytype) MyMaybe(extraIO(@TypeOf(f)).outputType) {
            assert(T == extraIO(@TypeOf(f)).inputType);
            switch (fa) {
                .Nothing => return .{ .Nothing = {} },
                .Just => |a| return .{ .Just = f(a) },
            }
        }

        pub fn pure(a: T) MyMaybe(T) {
            return .{ .Just = a };
        }
        pub fn bind(fa: MyMaybe(T), f: anytype) MyMaybe(extraIO(@TypeOf(f)).outputType.elem) {
            assert(T == extraIO(@TypeOf(f)).inputType);
            switch (fa) {
                .Nothing => return .{ .Nothing = {} },
                .Just => |a| return f(a),
            }
        }
    };
}

pub fn MyState(T: type) type {
    return struct {
        val: T,

        const elem = T;

        pub fn fmap(fa: MyState(T), f: anytype) MyState(extraIO(@TypeOf(f)).outputType) {
            assert(T == extraIO(@TypeOf(f)).inputType);
            return .{ .val = f(fa.val) };
        }

        pub fn pure(a: T) MyState(T) {
            return .{ .val = a };
        }

        pub fn bind(fa: MyState(T), f: anytype) MyState(extraIO(@TypeOf(f)).outputType.elem) {
            assert(T == extraIO(@TypeOf(f)).inputType);
            return f(fa.val);
        }
    };
}

pub fn MyReader(R: type, T: type) type {
    return struct {
        val: fn (R) T,

        const elem = T;

        pub fn fmap(fa: MyReader(R, T), f: anytype) MyReader(R, extraIO(@TypeOf(f)).outputType) {
            assert(T == extraIO(@TypeOf(f)).inputType);
            return .{ .val = mcomposefns(.{ fa.val, f }) };
        }
    };
}

pub fn ff1(i: i32) i64 {
    return (i + 1);
}

pub fn add_fun1(i: i64) i32 {
    return @intCast(i + 10);
}

pub fn add_fun2(i: i32) i64 {
    return (i + 100);
}

const S = struct { sv: *const fn (i64) i64 };

test "tmp1" {
    comptime var cc = mcomposefns(.{ add_fun1, add_fun2, add_fun1, add_fun2 });
    cc = cc;
    var s1: S = .{ .sv = mcomposefns(.{ add_fun1, add_fun2, cc }) };
    s1.sv = mcomposefns(.{ add_fun1, add_fun2, add_fun1, add_fun2 });
    std.debug.print("\n{any}\n", .{s1.sv(0)});
}

test "MyMonad" {
    const MR = MyReader(i32, i64);
    const r1 = MR{ .val = ff1 };
    std.debug.print("\n{any}\n", .{r1.val(0)});
    std.debug.print("\n{any}\n", .{r1.fmap(add_fun1).fmap(add_fun2).val(10)});

    const m1 = MyMaybe(i32).pure(10);
    const k1 = m1.bind(madd).bind(madd).bind(madd);
    const k2 = m1.bind(madd).bind(madd).bind(madd).bind(madd);
    std.debug.print("\n{any}\n", .{k1});
    std.debug.print("\n{any}\n", .{k2});

    const s1 = MyState(i32).pure(10);
    std.debug.print("\n{any}\n", .{s1});
    std.debug.print("\n{any}\n", .{s1.bind(sadd).bind(sadd)});
    const j1 = MK1{ .Pure = 10 };
    std.debug.print("\n{any}\n", .{j1});
    std.debug.print("\n{any}\n", .{j1.pfmap(add_fun2)});
}

// free
// data Free f a = Pure a | Free (f (Free f a))

pub fn MyFree(F: fn (type) type, T: anytype) type {
    return union(enum) {
        Pure: T,
        Free: F(*MyFree(F, T)),

        pub fn pfmap(fa: MyFree(F, T), f1: anytype) MyFree(F, extraIO(@TypeOf(f1)).outputType) {
            assert(T == extraIO(@TypeOf(f1)).inputType);
            switch (fa) {
                .Pure => |a| return .{ .Pure = f1(a) },
                .Free => |_| {
                    return .{ .Free = undefined };
                },
            }
        }
    };
}

const MK1 = MyFree(MyMaybe, i32);

pub fn madd(t: i32) MyMaybe(i32) {
    if (t > 100) {
        return .{ .Nothing = {} };
    } else {
        return .{ .Just = t + 35 };
    }
}

pub fn sadd(t: i32) MyState(i32) {
    return .{ .val = t + 1 };
}

test "MCF1" {
    // var p = .{ add_fun1, add_fun2, undefined, add_fun2 };
    const k = mcomposefns(.{ add_fun1, add_fun2, add_fun1, add_fun2 });
    std.debug.print("\n{any}\n", .{k(0)});
    std.debug.print("\n{any}\n", .{mcomposefns(.{ k, k })(0)});
}

/// Define a lambda type for composable function for function composition
pub fn ComposableFn(comptime cfg: anytype, comptime N: comptime_int, TS: [N]type) type {
    // The CompsableFn must has a function.
    comptime assert(N >= 2);
    return union(enum) {
        single_fn: if (N == 2) *const fn (A) B else void,
        composed_two: if (N == 3) ComposedTwoFn(A, TS[1], TS[2]) else void,
        composed_many: if (N > 3) ComposedManyFn(N, TS) else void,

        const Self = @This();
        const Error = cfg.error_set;
        const CompN = N;
        const CompTS = TS;
        const A = TS[0];
        const B = TS[N - 1];

        pub fn init(map_fn: *const fn (TS[0]) TS[1]) Self {
            return .{ .single_fn = map_fn };
        }

        pub fn initTwo(
            map_fn1: *const fn (TS[0]) TS[1],
            map_fn2: *const fn (TS[1]) TS[2],
        ) Self {
            return .{ .composed_two = .{
                .first_fn = map_fn1,
                .second_fn = map_fn2,
            } };
        }

        pub fn deinit(self: Self) void {
            if (N > 3) {
                self.composed_many.fns_array.deinit();
            }
        }

        fn ComposeType(comptime CompFn: type) type {
            const M = CompFn.CompN;
            const TS1 = CompFn.CompTS;
            return ComposableFn(cfg, N + M - 1, TS ++ TS1[1..].*);
        }

        /// The parametr compfn1 is a ComposableFn
        pub fn compose(
            self: Self,
            compfn1: anytype,
        ) Error!ComposeType(@TypeOf(compfn1)) {
            const M = @TypeOf(compfn1).CompN;
            const TS1 = @TypeOf(compfn1).CompTS;
            const InType = TS1[0];
            const RetType = TS1[M - 1];
            comptime assert(B == InType);
            // @compileLog(std.fmt.comptimePrint("A is: {any}", .{A}));
            // @compileLog(std.fmt.comptimePrint("B is: {any}", .{B}));
            // @compileLog(std.fmt.comptimePrint("TS is: {any}", .{TS}));
            // @compileLog(std.fmt.comptimePrint("RetType is: {any}", .{RetType}));

            if (N == 2) {
                switch (M) {
                    2 => {
                        // return a new composable function
                        return .{ .composed_two = ComposedTwoFn(A, B, RetType){
                            .first_fn = self.single_fn,
                            .second_fn = compfn1.single_fn,
                        } };
                    },
                    3 => {
                        var fns_array = try ArrayList(AnyFnPtr).initCapacity(cfg.allocator, N + 2);
                        fns_array.appendAssumeCapacity(@ptrCast(self.single_fn));
                        fns_array.appendAssumeCapacity(@ptrCast(compfn1.composed_two.first_fn));
                        fns_array.appendAssumeCapacity(@ptrCast(compfn1.composed_two.second_fn));
                        const NewTS = TS ++ TS1[1..].*;
                        // return a new composable function
                        return .{ .composed_many = ComposedManyFn(N + M - 1, NewTS){
                            .fns_array = fns_array,
                        } };
                    },
                    else => {
                        var fns_array = try ArrayList(AnyFnPtr).initCapacity(cfg.allocator, N + 2);
                        fns_array.appendAssumeCapacity(@ptrCast(self.single_fn));
                        try fns_array.appendSlice(compfn1.composed_many.fns_array.items);
                        const NewTS = TS ++ TS1[1..].*;
                        // return a new composable function
                        return .{ .composed_many = ComposedManyFn(N + M - 1, NewTS){
                            .fns_array = fns_array,
                        } };
                    },
                }
            } else if (N == 3) {
                var fns_array = try ArrayList(AnyFnPtr).initCapacity(cfg.allocator, N + 1);
                switch (M) {
                    2 => {
                        fns_array.appendAssumeCapacity(@ptrCast(self.composed_two.first_fn));
                        fns_array.appendAssumeCapacity(@ptrCast(self.composed_two.second_fn));
                        fns_array.appendAssumeCapacity(@ptrCast(compfn1.single_fn));
                    },
                    3 => {
                        fns_array.appendAssumeCapacity(@ptrCast(self.composed_two.first_fn));
                        fns_array.appendAssumeCapacity(@ptrCast(self.composed_two.second_fn));
                        fns_array.appendAssumeCapacity(@ptrCast(compfn1.composed_two.first_fn));
                        fns_array.appendAssumeCapacity(@ptrCast(compfn1.composed_two.second_fn));
                    },
                    else => {
                        fns_array.appendAssumeCapacity(@ptrCast(self.composed_two.first_fn));
                        fns_array.appendAssumeCapacity(@ptrCast(self.composed_two.second_fn));
                        try fns_array.appendSlice(compfn1.composed_many.fns_array.items);
                    },
                }
                const NewTS = TS ++ TS1[1..].*;
                // return a new composable function
                return .{ .composed_many = ComposedManyFn(N + M - 1, NewTS){
                    .fns_array = fns_array,
                } };
            } else {
                // @compileLog(std.fmt.comptimePrint("many_fn TS is: {any}", .{TS}));
                var fns_array = self.composed_many.fns_array;
                switch (M) {
                    2 => {
                        try fns_array.append(@ptrCast(compfn1.single_fn));
                    },
                    3 => {
                        try fns_array.append(@ptrCast(compfn1.composed_two.first_fn));
                        try fns_array.append(@ptrCast(compfn1.composed_two.second_fn));
                    },
                    else => {
                        try fns_array.appendSlice(compfn1.composed_many.fns_array.items);
                    },
                }
                const NewTS = TS ++ TS1[1..].*;
                // return a new composable function
                return .{ .composed_many = ComposedManyFn(N + M - 1, NewTS){
                    .fns_array = fns_array,
                } };
            }
        }

        /// This function append a map_fn to a composable function, the map_fn must be
        /// a single parameter function
        pub fn append(
            self: Self,
            map_fn: anytype,
        ) Error!ComposableFn(cfg, N + 1, TS ++ [1]type{MapFnRetType(@TypeOf(map_fn))}) {
            const InType = MapFnInType(@TypeOf(map_fn));
            const RetType = MapFnRetType(@TypeOf(map_fn));
            comptime assert(B == InType);

            if (N == 2) {
                // return a new composable function
                return .{ .composed_two = ComposedTwoFn(A, B, RetType){
                    .first_fn = self.single_fn,
                    .second_fn = map_fn,
                } };
            } else {
                var fns_array: ArrayList(AnyFnPtr) = undefined;
                if (N == 3) {
                    fns_array = try ArrayList(AnyFnPtr).initCapacity(cfg.allocator, N + 1);
                    fns_array.appendAssumeCapacity(@ptrCast(self.composed_two.first_fn));
                    fns_array.appendAssumeCapacity(@ptrCast(self.composed_two.second_fn));
                    fns_array.appendAssumeCapacity(@ptrCast(map_fn));
                } else {
                    fns_array = self.composed_many.fns_array;
                    try fns_array.append(@ptrCast(map_fn));
                }
                const NewTS = TS ++ [_]type{RetType};
                // return a new composable function
                return .{ .composed_many = ComposedManyFn(N + 1, NewTS){
                    .fns_array = fns_array,
                } };
            }
        }

        pub fn clone(self: Self) Error!Self {
            if (N > 3) {
                return .{ .composed_many = .{
                    .fns_array = try self.composed_many.fns_array.clone(),
                } };
            }
            return self;
        }

        pub fn call(self: Self, a: A) B {
            if (N == 2) {
                return self.single_fn(a);
            } else if (N == 3) {
                return self.composed_two.call(a);
            } else {
                return self.composed_many.call(a);
            }
        }
    };
}

const ComposeCfg = struct {
    allocator: Allocator,
    error_set: type,
};

fn getDefaultComposeCfg(allocator: Allocator) ComposeCfg {
    return .{
        .allocator = allocator,
        .error_set = Allocator.Error,
    };
}

fn div3FromF64(x: f64) u32 {
    const a: u32 = @intFromFloat(x);
    return @divFloor(a, 3);
}

fn rainbowColorFromU32(a: u32) RainbowColor {
    return @enumFromInt(@mod(a, 7));
}

test ComposableFn {
    const allocator = testing.allocator;
    const cfg = comptime getDefaultComposeCfg(allocator);
    const add10_types = [_]type{ u32, u32 };

    // test append function
    const comp_fn1 = ComposableFn(cfg, 2, add10_types).init(&testu.add10);
    defer comp_fn1.deinit();
    const comp_fn2 = try (try comp_fn1.clone()).append(&testu.add_pi_f64);
    defer comp_fn2.deinit();
    const comp_fn3 = try (try comp_fn2.clone()).append(&div3FromF64);
    defer comp_fn3.deinit();
    const comp_fn4 = try (try comp_fn3.clone()).append(&rainbowColorFromU32);
    defer comp_fn4.deinit();

    try testing.expectEqual(33, comp_fn1.call(23));
    try testing.expectEqual(36.14, comp_fn2.call(23));
    try testing.expectEqual(12, comp_fn3.call(23));
    try testing.expectEqual(.Indigo, comp_fn4.call(23));

    // test compose function
    const comp_fn11 = try (try comp_fn1.clone()).compose(comp_fn1);
    defer comp_fn11.deinit();
    const comp_fn12 = try (try comp_fn1.clone()).compose(comp_fn2);
    defer comp_fn12.deinit();
    const comp_fn13 = try (try comp_fn1.clone()).compose(comp_fn3);
    defer comp_fn13.deinit();
    const comp_fn14 = try (try comp_fn1.clone()).compose(comp_fn4);
    defer comp_fn14.deinit();

    try testing.expectEqual(43, comp_fn11.call(23));
    try testing.expectEqual(46.14, comp_fn12.call(23));
    try testing.expectEqual(15, comp_fn13.call(23));
    try testing.expectEqual(.Orange, comp_fn14.call(23));

    const comp_two = ComposableFn(cfg, 3, [_]type{ u32, f64, u32 }).initTwo(
        &testu.add_pi_f64,
        &div3FromF64,
    );
    const comp_fn21 = try comp_two.compose(comp_fn1);
    defer comp_fn21.deinit();
    const comp_fn22 = try (try comp_two.clone()).compose(comp_fn2);
    defer comp_fn22.deinit();
    const comp_fn23 = try (try comp_two.clone()).compose(comp_fn3);
    defer comp_fn23.deinit();
    const comp_fn24 = try (try comp_two.clone()).compose(comp_fn4);
    defer comp_fn24.deinit();

    try testing.expectEqual(18, comp_fn21.call(23));
    try testing.expectEqual(21.14, comp_fn22.call(23));
    try testing.expectEqual(7, comp_fn23.call(23));
    try testing.expectEqual(.Red, comp_fn24.call(23));

    const comp_fn31 = try (try comp_fn3.clone()).compose(comp_fn1);
    defer comp_fn31.deinit();
    const comp_fn32 = try (try comp_fn3.clone()).compose(comp_fn2);
    defer comp_fn32.deinit();
    const comp_fn33 = try (try comp_fn3.clone()).compose(comp_fn3);
    defer comp_fn33.deinit();
    const comp_fn34 = try (try comp_fn3.clone()).compose(comp_fn4);
    defer comp_fn34.deinit();

    try testing.expectEqual(22, comp_fn31.call(23));
    try testing.expectEqual(25.14, comp_fn32.call(23));
    try testing.expectEqual(8, comp_fn33.call(23));
    try testing.expectEqual(.Orange, comp_fn34.call(23));
}

fn ComposeTwoFn(map_fn1: anytype, map_fn2: anytype) type {
    const A = MapFnInType(@TypeOf(map_fn1));
    const B = MapFnRetType(@TypeOf(map_fn1));
    const B1 = MapFnInType(@TypeOf(map_fn2));
    const C = MapFnRetType(@TypeOf(map_fn2));
    comptime assert(B == B1);

    return struct {
        first_fn: *const fn (A) B,
        second_fn: *const fn (B) C,

        const Self = @This();
        pub fn call(self: Self, a: A) C {
            return self.second_fn(self.first_fn(a));
        }
    };
}

fn composeTwoFn(map_fn1: anytype, map_fn2: anytype) ComposeTwoFn(map_fn1, map_fn2) {
    return .{ .first_fn = map_fn1, .second_fn = map_fn2 };
}

/// Check the type E whether it is a ErrorUnion, if true then return a under
/// type of ErrorUnion, else just return type E.
pub fn isErrorUnionOrVal(comptime E: type) struct { bool, type } {
    const info = @typeInfo(E);
    const has_error = if (info == .ErrorUnion) true else false;
    const A = if (has_error) info.ErrorUnion.payload else E;
    return .{ has_error, A };
}

pub fn castInplaceValue(comptime T: type, val: anytype) T {
    const info = @typeInfo(@TypeOf(val));
    switch (info) {
        .Optional => {
            const v = val orelse return null;
            return castInplaceValue(std.meta.Child(T), v);
        },
        .Struct => {
            if (info.Struct.layout == .auto) {
                @compileError("Can't inplace cast struct with auto layout");
            }
            return @bitCast(val);
        },
        else => {
            return @bitCast(val);
        },
    }
}

pub fn defaultVal(comptime T: type) T {
    const info_a = @typeInfo(T);
    if (info_a == .Fn) {
        return getDefaultFn(T);
    } else if (info_a == .Pointer and @typeInfo(std.meta.Child(T)) == .Fn) {
        return getDefaultFn(std.meta.Child(T));
    }
    return std.mem.zeroes(T);
}

pub fn getDefaultFn(comptime Fn: type) fn (MapFnInType(Fn)) MapFnRetType(Fn) {
    return struct {
        const A = MapFnInType(Fn);
        const B = MapFnRetType(Fn);
        fn defaultFn(a: A) B {
            _ = a;
            return std.mem.zeroes(B);
        }
    }.defaultFn;
}

pub fn Maybe(comptime A: type) type {
    return ?A;
}

pub fn Array(comptime len: usize) TCtor {
    return struct {
        fn ArrayF(comptime A: type) type {
            return [len]A;
        }
    }.ArrayF;
}

pub fn FreeTFn(comptime T: type) type {
    return *const fn (T) void;
}

/// A empty free function, do nothing
pub fn getFreeNothing(comptime T: type) FreeTFn(T) {
    return struct {
        fn freeT(a: T) void {
            _ = a;
        }
    }.freeT;
}

/// A empty free function, do nothing
pub fn freeNothing(a: anytype) void {
    _ = a;
    return;
}

/// Clone a constructed data or referance a pointer
pub fn copyOrCloneOrRef(a: anytype) !@TypeOf(a) {
    const T = @TypeOf(a);
    const info = @typeInfo(T);
    switch (info) {
        .Struct, .Enum, .Union, .Opaque => {
            if (@hasDecl(T, "clone")) {
                return a.clone();
            }
        },
        .Pointer => {
            const Child = info.Pointer.child;
            const child_info = @typeInfo(Child);
            if (info.Pointer.size != .One) {
                @compileError("deinitOrUnref only for pointer that has only one element!");
            }
            switch (child_info) {
                .Struct, .Enum, .Union, .Opaque => {
                    if (@hasDecl(T, "strongRef")) {
                        return a.strongRef();
                    }
                },
                else => {},
            }
        },
        else => {},
    }

    return a;
}

/// get a normal deinit or unreference function for free some memory
pub fn getDeinitOrUnref(comptime T: type) FreeTFn(T) {
    return struct {
        fn freeT(a: T) void {
            deinitOrUnref(a);
        }
    }.freeT;
}

/// Deinit a constructed data or unreferance a pointer
pub fn deinitOrUnref(a: anytype) void {
    const T = @TypeOf(a);
    const info = @typeInfo(T);
    switch (info) {
        .Struct, .Enum, .Union, .Opaque => {
            if (@hasDecl(T, "deinit")) {
                a.deinit();
            }
        },
        .Pointer => {
            const Child = info.Pointer.child;
            const child_info = @typeInfo(Child);
            if (info.Pointer.size != .One) {
                @compileError("deinitOrUnref only for pointer that has only one element!");
            }
            switch (child_info) {
                .Struct, .Enum, .Union, .Opaque => {
                    if (@hasDecl(T, "strongUnref")) {
                        _ = a.strongUnref();
                    }
                },
                else => {},
            }
        },
        else => {},
    }
}

// pub fn MCF1(comptime fs: []const type) type {
//     var res = fs[0];
//     for (0..fs.len) |_| {
//         res = fs[1];
//         @compileError("aaaa");
//     }

//     return res;
// }

// test "MCF1" {
//     const g1 = [_]type{ fn (i32) i32, fn (i64) bool };
//     const k1 = comptime MCF1(g1[0..]);
//     std.debug.print("\n\n{any}\n\n", .{k1});
// }

// test "MyFun1" {
//     const ts = [_]type{ fn (i32) i64, fn (i64) i32 };
//     // const kks = [_]*const anyopaque{ &kf1, &kf2 };
//     // var fs = kks[0..];
//     // fs = fs;
//     const M1 = MyFun1(ts[0..], @constCast(fs));
//     std.debug.print("\n{any}\n", .{@TypeOf(M1)});
// }

// const FunPtrAndType = struct {
//     //
//     funPtr: *const anyopaque,
// };

// pub fn MyFun(it: type, ot: type) type {
//     return struct {
//         funPtrAndType: []const FunPtrAndType,

//         pub fn call(self: @This(), input: it) ot {
//             _ = self;
//             _ = input;
//             //一些汇编代码，绕过zig类型系统,直接调用 self.funPtrAndType里面的函数
//         }
//     };
// }

// test "MyFun" {
//     const MK = MyFun(i32, i32);
//     const mk = MK{ .funPtrAndType = &[_]FunPtrAndType{
//         .{ .funPtr = &kf1, .funType = fn (i32) i64 },
//         .{ .funPtr = &kf2, .funType = fn (i64) i32 },
//     } };
//     std.debug.print("\n{any}\n", .{(mk.call(1))});
//     std.debug.print("\n{any}\n", .{@TypeOf(composeMyFun(mk, mk))});
//     // const kkkk = composeMyFun(mk, mk);
//     // std.debug.print("\n{any}\n", .{kkkk.call(1)});
// }

// pub fn composeMyFun(myfun1: anytype, myfun2: anytype) MyFun(@TypeOf(myfun1).inputType, @TypeOf(myfun2).outputType) {
//     const fpa1 = myfun1.funPtrAndType;
//     const fpa2 = myfun2.funPtrAndType;
//     var result: [fpa1.len + fpa2.len]FunPtrAndType = undefined;
//     result = result;
//     for (0..result.len) |i| {
//         if (i < fpa1.len) {
//             result[i] = fpa1[i];
//         } else {
//             result[i] = fpa2[i - fpa1.len];
//         }
//     }
//     return .{ .funPtrAndType = result[0..] };
//     // return undefined;
// }

pub fn genStructField(i: usize, it: type, ot: type, dv: *const anyopaque) std.builtin.Type.StructField {
    var fmt: [10]u8 = undefined;
    return std.builtin.Type.StructField{
        .name = try std.fmt.bufPrintZ(&fmt, "s{d}", .{i}),
        .type = *const fn (it) ot,
        .default_value = dv,
        .is_comptime = false,
        .alignment = 8,
    };
}

// .{ &kf1, &kf2 }
pub fn FST(allFunPtrs: anytype) type {
    const info = @typeInfo(@TypeOf(allFunPtrs));
    switch (info) {
        .Struct => |st| {
            const fields = st.fields;
            var fieldStructsArr: [fields.len]std.builtin.Type.StructField = undefined;
            inline for (0..fields.len) |idx| {
                const funType = std.meta.Child(fields[idx].type);
                const it = extraIO(funType).inputType;
                const ot = extraIO(funType).outputType;
                const dv = @field(allFunPtrs, fields[idx].name);
                fieldStructsArr[idx] = genStructField(idx, it, ot, @ptrCast(&dv));
            }
            const Tmp = struct {};
            var tmpInfo = @typeInfo(Tmp);
            tmpInfo.Struct.fields = &fieldStructsArr;

            return @Type(tmpInfo);
        },
        else => unreachable,
    }
}

// const StructField = std.builtin.Type.StructField;
// pub fn gooLoop(args: anytype, fields: []const StructField, i: usize, input: extraIO(std.meta.Child(fields[0].type)).inputType) extraIO(std.meta.Child(fields[i].type)).outputType {
//     if (i == 0) {
//         .call(.auto, @field(args, fields[0].name), .{input});
//     } else {
//         .call(.auto, @field(args, fields[i].name), .{gooLoop(args, fields, i - 1, input)});
//     }
// }

// pub fn runFST(fst: anytype, input: i32) i32 {
//     switch (@typeInfo(@TypeOf(fst))) {
//         .Struct => |st| {
//             const fields = st.fields;
//             comptime gooLoop(fst, fields, fields.len - 1, input);
//         },
//         else => unreachable,
//     }
// }

pub fn printStructFields(a: type) void {
    switch (@typeInfo(a)) {
        .Struct => |st| {
            const fields = st.fields;
            inline for (0..fields.len) |i| {
                std.debug.print("\nname: {s}, type: {any} , alignement: {any}, default_val: {any}, is_comptime: {any}\n", .{ fields[i].name, fields[i].type, fields[i].alignment, fields[i].default_value, fields[i].is_comptime });
            }
        },
        else => unreachable,
    }
}

var globalOutputArray: [2]u128 = undefined;

pub fn myTrans(A: type, B: type, f: fn (A) B) fn (*const A) *const B {
    const Tmp = struct {
        pub fn f1(aRef: *const A) *const B {
            const ptr: *B = @ptrCast(@alignCast(&globalOutputArray));
            ptr.* = f(aRef.*);
            return ptr;
        }
    };
    return Tmp.f1;
}

pub fn toOpaque(A: type, B: type, f: fn (*const A) *const B) *const fn (*const anyopaque) *const anyopaque {
    const Tmp = struct {
        pub fn f1(oRef: *const anyopaque) *const anyopaque {
            const aRef: *const A = @ptrCast(@alignCast(oRef));
            return @ptrCast(f(aRef));
        }
    };
    return &Tmp.f1;
}

pub fn MF(A: type, B: type) type {
    return struct {
        mfarr: []*const anyopaque,

        pub fn call(self: @This(), input: A) B {
            var result: *const anyopaque = &input;
            for (0..self.mfarr.len) |i| {
                const tt: *const fn (*const anyopaque) *const anyopaque = @ptrCast(self.mfarr[i]);
                result = tt(result);
            }
            const ptr: *const B = @ptrCast(@alignCast(result));
            return ptr.*;
        }
    };
}

test "MyTrans" {
    // const tptr = &memptr;
    const nkf1 = myTrans(i32, i64, kf1);
    const okf1 = toOpaque(i32, i64, nkf1);

    const nkf10 = myTrans(i32, i64, kf10);
    const okf10 = toOpaque(i32, i64, nkf10);

    const nkf2 = myTrans(i64, i32, kf2);
    const okf2 = toOpaque(i64, i32, nkf2);

    var sot = [_]*const anyopaque{ okf1, okf2, okf1, okf2 };
    var mf = MF(i32, i32){ .mfarr = &sot };

    // const wkf10 = mf.myTrans1(i32, i64, kf10);
    // const rkf10 = toOpaque(i32, i64, wkf10);

    std.debug.print("\n{any}\n", .{mf.call(0)});
    mf.mfarr[0] = okf10;
    std.debug.print("\n{any}\n", .{mf.call(0)});
}

pub fn kf10(i: i32) i64 {
    return i + 1;
}

pub fn kf1(i: i32) i64 {
    return i + 10;
}

pub fn kf2(i: i64) i32 {
    const tmp: i32 = @intCast(i);
    return tmp + 100;
}
