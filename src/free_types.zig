//! Define some types to implement Free Structure in Haskell, such as Free Monad,
//! Free Applicative, etc.

const std = @import("std");
const base = @import("base.zig");
const functor = @import("functor.zig");
const applicative = @import("applicative.zig");
const monad = @import("monad.zig");
const arraym = @import("array_list_monad.zig");
const state = @import("state.zig");
const testu = @import("test_utils.zig");

const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Maybe = base.Maybe;
const ArrayList = std.ArrayList;

const TCtor = base.TCtor;

const MapFnInType = base.MapFnInType;
const MapFnRetType = base.MapFnRetType;
const MapLamInType = base.MapLamInType;
const MapLamRetType = base.MapLamRetType;

const FMapMode = base.FMapMode;
const MapFnKind = base.MapFnKind;
const isMapRef = base.isMapRef;
const isInplaceMap = base.isInplaceMap;
const isErrorUnionOrVal = base.isErrorUnionOrVal;

const Functor = functor.Functor;
const NatTrans = functor.NatTrans;
const Applicative = applicative.Applicative;
const Monad = monad.Monad;
const ArrayListMonadImpl = arraym.ArrayListMonadImpl;

const FunctorFxTypes = functor.FunctorFxTypes;
const ApplicativeFxTypes = applicative.ApplicativeFxTypes;
const MonadFxTypes = monad.MonadFxTypes;
const runDo = monad.runDo;

const DEFAULT_LEN: usize = 8;

/// This is type constructor of Free Monad, the parameter F must be a Functor,
/// and all value constructors of F must take only one parameter.
/// If you need a value constructor with multiple parameters, you can curry it
/// into multiple value constructors taht take one parameter.
pub fn FreeMonad(comptime F: TCtor, comptime A: type) type {
    return FreeM(F)(A);
}

// The OpLam is a natural transformation between Id a annd F a.
const FOpEnumInt = u16;

// The AnyOpLam is a dummy type for specify OpLam
const AnyOpLam = extern struct {
    lam_ctx: u64,
    const Self = @This();
    pub fn call(self: Self) void {
        _ = self;
    }
};

/// The type function FreeM is currying form of type constructor FreeMonad.
pub fn FreeM(comptime F: TCtor) TCtor {
    return struct {
        fn FreeF(comptime A: type) type {
            return union(enum) {
                // The FreeMonad(F, A) type that defined by Haskell is
                // data Free f a = Pure a
                //               | Free (f (Free f a)
                // The value Free (f2 (Free (f1 (Free (f0 pure_m))))) layout is
                // ( pure_m, [f0, f1, f2] )

                // pure value of FreeMonad(F, A)
                pure_m: A,
                // tuple of (pure FreeMonad(F, A), reversed f list), every f is just a
                // build information of operator in F.
                free_m: struct { *Self, ArrayList(FOpInfo) },

                const Self = @This();
                const BaseType = A;

                // The build information of operator in F for FreeMonad(F, A)
                pub const FOpInfo = struct {
                    op_e: FOpEnumInt,
                    op_lam: AnyOpLam,
                };
                // TODO: use static hashmap to get key-value relation of F and CtorDefs
                const f_op_ctors = GetOpCtors(F, A);

                pub fn deinit(self: Self) void {
                    if (self == .free_m) {
                        const allocator = self.free_m[1].allocator;
                        self.free_m[1].deinit();
                        allocator.destroy(self.free_m[0]);
                    }
                }

                pub inline fn pureM(a: A) Self {
                    return Self{ .pure_m = a };
                }

                pub inline fn freeM(allocator: Allocator, a: A, fs: []FOpInfo) !Self {
                    const new_pure_m = try allocator.create(Self);
                    new_pure_m.* = .{ .pure_m = a };
                    var flist = try ArrayList(FOpInfo).initCapacity(allocator, fs.len);
                    flist.appendSliceAssumeCapacity(fs);
                    return .{ .free_m = .{ new_pure_m, flist } };
                }

                // This function has move semantics, all value in self move to new self.
                pub fn appendValFn(self: Self, allocator: Allocator, f: FOpInfo) !Self {
                    if (self == .pure_m) {
                        var flist = try ArrayList(FOpInfo).initCapacity(allocator, DEFAULT_LEN);
                        flist.appendAssumeCapacity(f);
                        const new_pure_m = try allocator.create(Self);
                        new_pure_m.* = .{ .pure_m = self.pure_m };
                        return .{ .free_m = .{ new_pure_m, flist } };
                    } else {
                        var flist = self.free_m[1];
                        try flist.append(f);
                        return .{ .free_m = .{ self.free_m[0], flist } };
                    }
                }

                // This function has move semantics, all value in self move to new self.
                pub fn appendValFns(self: Self, allocator: Allocator, fs: []FOpInfo) !Self {
                    if (self == .pure_m) {
                        var flist = try ArrayList(FOpInfo).initCapacity(allocator, fs.len);
                        flist.appendSliceAssumeCapacity(fs);
                        const new_pure_m = try allocator.create(Self);
                        new_pure_m.* = .{ .pure_m = self.pure_m };
                        return .{ .free_m = .{ new_pure_m, flist } };
                    } else {
                        var flist = self.free_m[1];
                        try flist.appendSlice(fs);
                        return .{ .free_m = .{ self.free_m[0], flist } };
                    }
                }

                /// Tear down a FreeMonad(F, A) using iteration.
                pub fn iter(self: Self, f: *const fn (F(A)) A) A {
                    if (self == .pure_m) {
                        return self.pure_m;
                    }

                    var acc_a = self.free_m[0].pure_m;
                    for (self.free_m[1].items) |op_info| {
                        const val_ctor_info = f_op_ctors[op_info.op_e];
                        const fa = val_ctor_info.callValCtorFn(
                            op_info.op_lam,
                            @constCast(&[_]A{acc_a}),
                        );
                        acc_a = f(fa);
                    }
                    return acc_a;
                }

                // pub fn hoistFree(
                //     self: Self,
                //     comptime NatImpl: type,
                //     nat_impl: NatImpl,
                // ) FreeMonad(NatImpl.G, A) {
                //     comptime assert(F == NatImpl.F);
                //     if (self == .pure_m) {
                //         return .{ .pure_m = self.pure_m };
                //     }

                //     const allocator = self.free_m[1].allocator;
                //     const new_pure_m = try allocator.create(Self);
                //     new_pure_m.* = .{ .pure_m = self.free_m[0].pure_m.* };
                //     const fs = self.free_m[1].items;
                //     var flist = try ArrayList(FOpInfo).initCapacity(allocator, fs.len);
                //     for (fs) |ctor_idx| {
                //         const val_ctor_info = f_op_ctors[ctor_idx];
                //         flist.appendAssumeCapacity(compose(nat_impl.trans, origin_f));
                //     }
                //     return .{ .free_m = .{ new_pure_m, flist } };
                // }

                /// Evaluate a FreeMonad(F, A) to a Monad M(A) by given a natural
                /// transformation of F and M. This is equivalent to a monad homomorphism
                /// of FreeMoand(F, A) to M(A).
                pub fn foldFree(
                    self: Self,
                    nat_impl: anytype,
                    m_impl: anytype,
                ) @TypeOf(m_impl).MbType(A) {
                    const NatImpl = @TypeOf(nat_impl);
                    const MImpl = @TypeOf(m_impl);
                    comptime assert(F == NatImpl.F);
                    comptime assert(MImpl.F == NatImpl.G);
                    if (self == .pure_m) {
                        return @constCast(&m_impl).pure(self.pure_m);
                    }

                    var acc_m = try @constCast(&m_impl).pure(self.free_m[0].pure_m);
                    for (self.free_m[1].items) |op_info| {
                        const fm_op_ctors = GetOpCtors(F, MImpl.F(A));
                        const val_ctor_info = fm_op_ctors[op_info.op_e];
                        const f_acc_m = val_ctor_info.callValCtorFn(
                            op_info.op_lam,
                            @constCast(&[_]MImpl.F(A){acc_m}),
                        );
                        const m_acc_m = try nat_impl.trans(MImpl.F(A), f_acc_m);
                        acc_m = try @constCast(&m_impl).join(A, m_acc_m);
                        MImpl.deinitFa(m_acc_m, base.getDeinitOrUnref(MImpl.F(A)));
                    }
                    return acc_m;
                }
            };
        }
    }.FreeF;
}

fn GetCtorDefs(comptime F: TCtor, comptime A: type) type {
    comptime {
        switch (@typeInfo(F(A))) {
            .Struct, .Enum, .Union, .Opaque => {
                if (@hasDecl(F(A), "OpCtorDefs")) {
                    return F(A).OpCtorDefs;
                }
            },
            else => {},
        }

        const mapCtorDefs = std.StaticStringMap(type).initComptime(.{
            .{ @typeName(Maybe(A)), MaybeCtorDefs(A) },
        });

        const ctor_defs = mapCtorDefs.get(@typeName(F(A)));
        if (ctor_defs == null) {
            @compileError("The user customered Functor must has OpCtorDefs!");
        }
        return ctor_defs.?;
    }
}

fn OpCtorsType(comptime F: TCtor, comptime A: type) type {
    const OpCtorDefs = GetCtorDefs(F, A);
    const CtorEnum = std.meta.DeclEnum(OpCtorDefs);
    const enum_fields = std.meta.fields(CtorEnum);
    return [enum_fields.len]OpCtorInfo(A, CtorEnum, OpCtorDefs);
}

fn OpCtorInfo(
    comptime A: type,
    comptime ValCtorE: type,
    comptime OpDefs: type,
) type {
    const first_op_e = @as(ValCtorE, @enumFromInt(0));
    const FirstOpLam = @field(OpDefs, @tagName(first_op_e));
    const first_fn_info = @typeInfo(@TypeOf(FirstOpLam.call));
    const OpCtorRetType = first_fn_info.Fn.return_type.?;
    return struct {
        ctor_e: ValCtorE,
        params_len: u8,

        const Self = @This();
        pub fn callValCtorFn(self: Self, op_lam: AnyOpLam, as: []A) OpCtorRetType {
            switch (self.ctor_e) {
                inline else => |e| {
                    // std.debug.print("ValCtor enum: {any}\n", .{e});
                    // std.debug.print(
                    //     "as.len = {d}, params_len = {d}\n",
                    //     .{ as.len, self.params_len },
                    // );
                    if (self.params_len > 0) {
                        std.debug.assert(as.len == self.params_len);
                    } else {
                        std.debug.assert(as.len == 1);
                        base.deinitOrUnref(as[0]);
                    }
                    const OpLam = @field(OpDefs, @tagName(e));
                    const Args = std.meta.ArgsTuple(@TypeOf(OpLam.call));
                    var args: Args = undefined;
                    const args_fields = std.meta.fields(Args);
                    assert(args_fields.len - 1 == self.params_len);
                    // first parameter is lambda self
                    args[0] = @as(OpLam, @bitCast(op_lam));
                    comptime var i = 1;
                    inline while (i < @typeInfo(Args).Struct.fields.len) : (i += 1) {
                        args[i] = as[i - 1];
                    }
                    return @call(.auto, OpLam.call, args);
                },
            }
        }
    };
}

pub fn GetOpCtors(
    comptime F: TCtor,
    comptime A: type,
) OpCtorsType(F, A) {
    const OpCtorDefs = GetCtorDefs(F, A);
    const CtorEnum = std.meta.DeclEnum(OpCtorDefs);
    const enum_fields = std.meta.fields(CtorEnum);

    var op_ctors: [enum_fields.len]OpCtorInfo(A, CtorEnum, OpCtorDefs) = undefined;
    inline for (enum_fields, 0..) |field, i| {
        const name = field.name;
        const OpLam = @field(OpCtorDefs, name);
        const fn_info = @typeInfo(@TypeOf(OpLam.call));
        const params_len = fn_info.Fn.params.len;
        const ctor_e = @as(CtorEnum, @enumFromInt(i));
        op_ctors[i].ctor_e = ctor_e;
        // The call function of OpLam has a self parameter, all real parameters are not
        // include it.
        op_ctors[i].params_len = params_len - 1;
    }
    return op_ctors;
}

/// All value constructors for Maybe Functor
fn MaybeCtorDefs(comptime A: type) type {
    return struct {
        pub const Nothing = NothingLam;
        pub const Just = JustLam;

        // Value constructor lambdas for Maybe
        const NothingLam = extern struct {
            lam_ctx: u64,

            const Self = @This();
            pub fn build() Self {
                return .{ .lam_ctx = 0 };
            }

            pub fn deinit(self: Self) void {
                _ = self;
            }

            pub fn call(self: Self) Maybe(A) {
                _ = self;
                return null;
            }
        };

        const JustLam = extern struct {
            lam_ctx: u64,

            const Self = @This();
            pub fn build() Self {
                return .{ .lam_ctx = 0 };
            }

            pub fn deinit(self: Self) void {
                _ = self;
            }

            pub fn call(self: Self, a: A) Maybe(A) {
                _ = self;
                return a;
            }
        };
    };
}

fn maybeToA(comptime A: type) *const fn (a: Maybe(A)) A {
    return struct {
        fn iterFn(a: Maybe(A)) A {
            return a orelse 0;
        }
    }.iterFn;
}

test "FreeMonad(F, A) constructor functions and iter" {
    const allocator = testing.allocator;

    var a: u32 = 42;
    _ = &a;
    const pure_freem = FreeMonad(Maybe, u32).pureM(a);
    try testing.expectEqual(42, pure_freem.pure_m);

    const MaybeCtorEnum = std.meta.DeclEnum(MaybeCtorDefs(u32));
    const Nothing: u16 = @intFromEnum(MaybeCtorEnum.Nothing);
    const buildNothing = MaybeCtorDefs(u32).Nothing.build;
    const Just: u16 = @intFromEnum(MaybeCtorEnum.Just);
    const buildJust = MaybeCtorDefs(u32).Just.build;
    const FOpInfo = comptime FreeMonad(Maybe, u32).FOpInfo;
    const just_fns = &[_]FOpInfo{
        .{ .op_e = Just, .op_lam = @bitCast(buildNothing()) },
    };
    var free_maybe = try FreeMonad(Maybe, u32).freeM(allocator, 42, @constCast(just_fns));
    try testing.expectEqual(42, free_maybe.iter(maybeToA(u32)));

    free_maybe = try free_maybe.appendValFn(
        allocator,
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    );
    try testing.expectEqual(42, free_maybe.iter(maybeToA(u32)));

    const just_fns3 = &[_]FOpInfo{
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
        .{ .op_e = Nothing, .op_lam = @bitCast(buildNothing()) },
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    };
    free_maybe = try free_maybe.appendValFns(allocator, @constCast(just_fns3));
    defer free_maybe.deinit();
    try testing.expectEqual(0, free_maybe.iter(maybeToA(u32)));
}

const MWriterMaybe = state.MWriterMaybe;

pub const MaybeShowNatImpl = struct {
    allocator: Allocator,

    const Self = @This();

    pub const F = Maybe;
    pub const G = MWriterMaybe(ArrayList(u8));
    pub const Error = Allocator.Error;

    pub fn trans(self: Self, comptime A: type, fa: F(A)) Error!G(A) {
        if (fa) |a| {
            const just_str = "Just ";
            var array = try ArrayList(u8).initCapacity(self.allocator, just_str.len);
            array.appendSliceAssumeCapacity(just_str);
            return .{ .a = a, .w = array };
        } else {
            // return empty ArrayList
            const array = ArrayList(u8).init(self.allocator);
            return .{ .a = @as(Maybe(A), null), .w = array };
        }
    }
};

const MaybeToArrayListNatImpl = functor.MaybeToArrayListNatImpl;
const MWriterMaybeMonadImpl = state.MWriterMaybeMonadImpl;

fn ArrayListMonoidImpl(comptime T: type) type {
    return struct {
        allocator: Allocator,

        const Self = @This();
        pub const M = ArrayList(T);
        pub const Error = Allocator.Error;

        pub fn mempty(self: Self) Error!M {
            return ArrayList(T).init(self.allocator);
        }

        pub fn mappend(self: Self, ma: M, mb: M) Error!M {
            _ = self;
            var array_c = try ArrayList(T).initCapacity(ma.allocator, ma.items.len + mb.items.len);
            array_c.appendSliceAssumeCapacity(ma.items);
            array_c.appendSliceAssumeCapacity(mb.items);
            return array_c;
        }
    };
}

test "FreeMonad(F, A) constructor functions and foldFree" {
    const allocator = testing.allocator;
    const ArrayListMonad = Monad(ArrayListMonadImpl);
    const array_monad = ArrayListMonad.init(.{ .allocator = allocator });
    const NatMaybeToArray = NatTrans(MaybeToArrayListNatImpl);
    const nat_maybe_array = NatMaybeToArray.init(.{ .instanceArray = .{ .allocator = allocator } });

    const ShowMonadImpl = MWriterMaybeMonadImpl(ArrayListMonoidImpl(u8), ArrayList(u8));
    const ShowMonad = Monad(ShowMonadImpl);
    const array_monoid = ArrayListMonoidImpl(u8){ .allocator = allocator };
    const show_monad = ShowMonad.init(.{ .monoid_impl = array_monoid });
    const NatMaybeToShow = NatTrans(MaybeShowNatImpl);
    const nat_maybe_show = NatMaybeToShow.init(.{ .allocator = allocator });

    var a: u32 = 42;
    _ = &a;

    const MaybeCtorEnum = std.meta.DeclEnum(MaybeCtorDefs(u32));
    const Nothing: u16 = @intFromEnum(MaybeCtorEnum.Nothing);
    const buildNothing = MaybeCtorDefs(u32).Nothing.build;
    const Just: u16 = @intFromEnum(MaybeCtorEnum.Just);
    const buildJust = MaybeCtorDefs(u32).Just.build;
    const FOpInfo = comptime FreeMonad(Maybe, u32).FOpInfo;
    const just_fns = &[_]FOpInfo{
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    };
    var free_maybe = try FreeMonad(Maybe, u32).freeM(allocator, 42, @constCast(just_fns));
    defer free_maybe.deinit();

    const folded = try free_maybe.foldFree(nat_maybe_array, array_monad);
    defer folded.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{42}, folded.items);
    const show_writer = try free_maybe.foldFree(nat_maybe_show, show_monad);
    defer show_writer.deinit();
    try testing.expectEqual(42, show_writer.a);
    try testing.expectEqualSlices(u8, "Just ", show_writer.w.items);

    free_maybe = try free_maybe.appendValFn(
        allocator,
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    );
    const folded1 = try free_maybe.foldFree(nat_maybe_array, array_monad);
    defer folded1.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{42}, folded1.items);
    const show1_writer = try free_maybe.foldFree(nat_maybe_show, show_monad);
    defer show1_writer.deinit();
    try testing.expectEqual(42, show1_writer.a);
    try testing.expectEqualSlices(u8, "Just Just ", show1_writer.w.items);

    const just_fns3 = &[_]FOpInfo{
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
        .{ .op_e = Nothing, .op_lam = @bitCast(buildNothing()) },
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    };
    free_maybe = try free_maybe.appendValFns(allocator, @constCast(just_fns3));
    const folded2 = try free_maybe.foldFree(nat_maybe_array, array_monad);
    defer folded2.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{}, folded2.items);
    const show2_writer = try free_maybe.foldFree(nat_maybe_show, show_monad);
    defer show2_writer.deinit();
    try testing.expectEqual(null, show2_writer.a);
    try testing.expectEqualSlices(u8, "Just ", show2_writer.w.items);
}

/// The Monad instance of FreeMonad, the parameter FunF is a Functor.
pub fn FreeMonadImpl(comptime FunF: TCtor) type {
    return struct {
        allocator: Allocator,

        const Self = @This();

        /// Constructor Type for Functor, Applicative, Monad, ...
        pub const F = FreeM(FunF);

        /// Get base type of FreeMonad(F, A), it is must just is A.
        pub fn BaseType(comptime FreeFA: type) type {
            return FreeFA.BaseType;
        }

        pub const Error = Allocator.Error;

        pub const FxTypes = FunctorFxTypes(F, Error);
        pub const FaType = FxTypes.FaType;
        pub const FbType = FxTypes.FbType;
        pub const FaLamType = FxTypes.FaLamType;
        pub const FbLamType = FxTypes.FbLamType;

        const AFxTypes = ApplicativeFxTypes(F, Error);
        pub const APaType = AFxTypes.APaType;
        pub const AFbType = AFxTypes.AFbType;

        pub const MbType = MonadFxTypes(F, Error).MbType;

        pub fn deinitFa(
            fa: anytype, // FreeMonad(F, A)
            comptime free_fn: *const fn (BaseType(@TypeOf(fa))) void,
        ) void {
            if (fa == .pure_m) {
                free_fn(fa.pure_m);
            } else {
                free_fn(fa.free_m[0].pure_m);
                const allocator = fa.free_m[2];
                allocator.destroy(fa.free_m[0]);
                fa.free_m[1].deinit();
            }
        }

        pub fn fmap(
            self: *Self,
            comptime K: MapFnKind,
            map_fn: anytype,
            fa: FaType(K, @TypeOf(map_fn)),
        ) FbType(@TypeOf(map_fn)) {
            // const A = MapFnInType(@TypeOf(map_fn));
            const B = MapFnRetType(@TypeOf(map_fn));
            const has_err, const _B = comptime isErrorUnionOrVal(B);

            const is_pure, const b = if (comptime isMapRef(K)) blk_t: {
                const is_pure = fa.* == .pure_m;
                const p_a = if (is_pure) &fa.pure_m else &fa.free_m[0].pure_m;
                break :blk_t .{ is_pure, map_fn(p_a) };
            } else blk_f: {
                const is_pure = fa == .pure_m;
                const a = if (is_pure) fa.pure_m else fa.free_m[0].pure_m;
                break :blk_f .{ is_pure, map_fn(a) };
            };
            const _b = if (has_err) try b else b;
            if (is_pure) {
                return .{ .pure_m = _b };
            } else {
                const new_pure_m = try self.allocator.create(FreeMonad(FunF, _B));
                new_pure_m.* = .{ .pure_m = _b };
                return .{ .free_m = .{ new_pure_m, try fa.free_m[1].clone() } };
            }
        }

        pub fn fmapLam(
            self: *Self,
            comptime K: MapFnKind,
            map_lam: anytype,
            fa: FaLamType(K, @TypeOf(map_lam)),
        ) FbLamType(@TypeOf(map_lam)) {
            const B = MapLamRetType(@TypeOf(map_lam));
            const has_err, const _B = comptime isErrorUnionOrVal(B);

            const is_pure, const b = if (comptime isMapRef(K)) blk_t: {
                const is_pure = fa.* == .pure_m;
                const p_a = if (is_pure) &fa.pure_m else &fa.free_m[0].pure_m;
                break :blk_t .{ is_pure, map_lam.call(p_a) };
            } else blk_f: {
                const is_pure = fa == .pure_m;
                const a = if (is_pure) fa.pure_m else fa.free_m[0].pure_m;
                break :blk_f .{ is_pure, map_lam.call(a) };
            };
            const _b = if (has_err) try b else b;
            if (is_pure) {
                return .{ .pure_m = _b };
            } else {
                const new_pure_m = try self.allocator.create(FreeMonad(FunF, _B));
                new_pure_m.* = .{ .pure_m = _b };
                return .{ .free_m = .{ new_pure_m, try fa.free_m[1].clone() } };
            }
        }

        pub fn pure(self: *Self, a: anytype) APaType(@TypeOf(a)) {
            _ = self;
            const has_err, const _A = comptime isErrorUnionOrVal(@TypeOf(a));
            const _a: _A = if (has_err) try a else a;
            return .{ .pure_m = _a };
        }

        pub fn fapply(
            self: *Self,
            comptime A: type,
            comptime B: type,
            // applicative function: F (a -> b), fa: F a
            ff: F(*const fn (A) B),
            fa: F(A),
        ) AFbType(B) {
            const has_err, const _B = comptime isErrorUnionOrVal(B);

            if (ff == .pure_m) {
                return self.fmap(.NewValMap, ff.pure_m, fa);
            }

            const map_fn = ff.free_m[0].pure_m;
            if (fa == .pure_m) {
                const b = map_fn(fa.pure_m);
                const _b = if (has_err) try b else b;
                const new_pure_m = try self.allocator.create(F(_B));
                new_pure_m.* = .{ .pure_m = _b };
                return .{ .free_m = .{ new_pure_m, try ff.free_m[1].clone() } };
            } else {
                const b = map_fn(fa.free_m[0].pure_m);
                const _b = if (has_err) try b else b;
                const new_pure_m = try self.allocator.create(F(_B));
                new_pure_m.* = .{ .pure_m = _b };
                const len = fa.free_m[1].items.len + ff.free_m[1].items.len;
                var flist = try @TypeOf(fa.free_m[1]).initCapacity(self.allocator, len);
                flist.appendSliceAssumeCapacity(fa.free_m[1].items);
                flist.appendSliceAssumeCapacity(ff.free_m[1].items);
                return .{ .free_m = .{ new_pure_m, flist } };
            }
        }

        pub fn fapplyLam(
            self: *Self,
            comptime A: type,
            comptime B: type,
            // applicative function: F (a -> b), fa: F a
            flam: anytype, // a F(lambda) that present F(*const fn (A) B),
            fa: F(A),
        ) AFbType(B) {
            const has_err, const _B = comptime isErrorUnionOrVal(B);

            if (flam == .pure_m) {
                return try self.fmapLam(.NewValMap, flam.pure_m, fa);
            }

            const map_lam = flam.free_m[0].pure_m;
            if (fa == .pure_m) {
                const b = map_lam.call(fa.pure_m);
                const _b = if (has_err) try b else b;
                const new_pure_m = try self.allocator.create(F(_B));
                new_pure_m.* = .{ .pure_m = _b };
                return .{ .free_m = .{ new_pure_m, try flam.free_m[1].clone() } };
            } else {
                const b = map_lam.call(fa.free_m[0].pure_m);
                const _b = if (has_err) try b else b;
                const new_pure_m = try self.allocator.create(F(_B));
                new_pure_m.* = .{ .pure_m = _b };
                const len = fa.free_m[1].items.len + flam.free_m[1].items.len;
                var flist = try @TypeOf(fa.free_m[1]).initCapacity(self.allocator, len);
                flist.appendSliceAssumeCapacity(fa.free_m[1].items);
                flist.appendSliceAssumeCapacity(flam.free_m[1].items);
                return .{ .free_m = .{ new_pure_m, flist } };
            }
        }
        pub fn bind(
            self: *Self,
            comptime A: type,
            comptime B: type,
            // monad function: (a -> M b), ma: M a
            ma: F(A),
            k: *const fn (*Self, A) MbType(B),
        ) MbType(B) {
            if (ma == .pure_m) {
                return try k(self, ma.pure_m);
            }

            const freem = try k(self, ma.free_m[0].pure_m);
            if (freem == .pure_m) {
                const new_pure_m = try self.allocator.create(F(B));
                new_pure_m.* = .{ .pure_m = freem.pure_m };
                return .{ .free_m = .{ new_pure_m, try ma.free_m[1].clone() } };
            } else {
                var flist = freem.free_m[1];
                try flist.appendSlice(ma.free_m[1].items);
                return .{ .free_m = .{ freem.free_m[0], flist } };
            }
        }

        pub fn join(
            self: *Self,
            comptime A: type,
            mma: F(F(A)),
        ) MbType(A) {
            if (mma == .pure_m) {
                return mma.pure_m;
            }

            // mma.free_m[0] is a pointer of pure(FreeMonad(F, A)), so the
            // mma.free_m[0].pure_m is FreeMonad(F, A).
            if (mma.free_m[0].pure_m == .pure_m) {
                // mma.free_m[0].pure_m is a pure value of FreeMonad(F, A).
                const new_pure_m = try self.allocator.create(F(A));
                new_pure_m.* = .{ .pure_m = mma.free_m[0].pure_m.pure_m };
                return .{ .free_m = .{ new_pure_m, try mma.free_m[1].clone() } };
            }

            // mma.free_m[0].pure_m is a impure value of FreeMonad(F, A).
            var flist = mma.free_m[0].pure_m.free_m[1];
            try flist.appendSlice(mma.free_m[1].items);
            return .{ .free_m = .{ mma.free_m[0].pure_m.free_m[0], flist } };
        }
    };
}

// These functions are defined for unit test
const add10 = testu.add10;
const add_pi_f64 = &testu.add_pi_f64;
const mul_pi_f64 = &testu.mul_pi_f64;

const Add_x_f64_Lam = testu.Add_x_f64_Lam;

test "FreeMonad(F, A) fmap" {
    const allocator = testing.allocator;
    const FreeMFunctor = Functor(FreeMonadImpl(Maybe));
    var freem_functor = FreeMFunctor.init(.{ .allocator = allocator });

    const ShowMonadImpl = MWriterMaybeMonadImpl(ArrayListMonoidImpl(u8), ArrayList(u8));
    const ShowMonad = Monad(ShowMonadImpl);
    const array_monoid = ArrayListMonoidImpl(u8){ .allocator = allocator };
    const show_monad = ShowMonad.init(.{ .monoid_impl = array_monoid });
    const NatMaybeToShow = NatTrans(MaybeShowNatImpl);
    const nat_maybe_show = NatMaybeToShow.init(.{ .allocator = allocator });

    var a: u32 = 42;
    _ = &a;
    // const pure_freem = .{ .pure_m = a };
    const pure_freem = FreeMonad(Maybe, u32).pureM(@as(u32, 42));
    const pure_freem1 = try freem_functor.fmap(.NewValMap, add_pi_f64, pure_freem);
    try testing.expectEqual(45.14, pure_freem1.iter(maybeToA(f64)));
    const show_writer = try pure_freem1.foldFree(nat_maybe_show, show_monad);
    defer show_writer.deinit();
    try testing.expectEqual(45.14, show_writer.a);
    try testing.expectEqualSlices(u8, "", show_writer.w.items);

    const MaybeCtorEnum = std.meta.DeclEnum(MaybeCtorDefs(u32));
    const Just: u16 = @intFromEnum(MaybeCtorEnum.Just);
    const buildJust = MaybeCtorDefs(u32).Just.build;
    // const Nothing: u16 = @intFromEnum(MaybeCtorEnum.Nothing);
    const FOpInfo = comptime FreeMonad(Maybe, u32).FOpInfo;
    const just_fns2 = &[_]FOpInfo{
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    };
    const free_maybe = try pure_freem.appendValFns(allocator, @constCast(just_fns2));
    defer free_maybe.deinit();
    const free_maybe1 = try freem_functor.fmap(.NewValMap, add10, free_maybe);
    defer free_maybe1.deinit();
    try testing.expectEqual(52, free_maybe1.iter(maybeToA(u32)));
    const show1_writer = try free_maybe1.foldFree(nat_maybe_show, show_monad);
    defer show1_writer.deinit();
    try testing.expectEqual(52, show1_writer.a);
    try testing.expectEqualSlices(u8, "Just Just ", show1_writer.w.items);

    const add_x_f64_lam = Add_x_f64_Lam{ ._x = 3.14 };
    const free_maybe2 = try freem_functor.fmapLam(.NewValMap, add_x_f64_lam, free_maybe1);
    defer free_maybe2.deinit();
    try testing.expectEqual(55.14, free_maybe2.iter(maybeToA(f64)));
    const show2_writer = try free_maybe2.foldFree(nat_maybe_show, show_monad);
    defer show2_writer.deinit();
    try testing.expectEqual(55.14, show2_writer.a);
    try testing.expectEqualSlices(u8, "Just Just ", show2_writer.w.items);
}

test "FreeMonad(F, A) pure and fapply" {
    const allocator = testing.allocator;
    const FreeMApplicative = Applicative(FreeMonadImpl(Maybe));
    var freem_applicative = FreeMApplicative.init(.{ .allocator = allocator });

    const ShowMonadImpl = MWriterMaybeMonadImpl(ArrayListMonoidImpl(u8), ArrayList(u8));
    const ShowMonad = Monad(ShowMonadImpl);
    const array_monoid = ArrayListMonoidImpl(u8){ .allocator = allocator };
    const show_monad = ShowMonad.init(.{ .monoid_impl = array_monoid });
    const NatMaybeToShow = NatTrans(MaybeShowNatImpl);
    const nat_maybe_show = NatMaybeToShow.init(.{ .allocator = allocator });

    var a: u32 = 42;
    _ = &a;
    const MaybeCtorEnum = std.meta.DeclEnum(MaybeCtorDefs(u32));
    const Nothing: u16 = @intFromEnum(MaybeCtorEnum.Nothing);
    const buildNothing = MaybeCtorDefs(u32).Nothing.build;
    const Just: u16 = @intFromEnum(MaybeCtorEnum.Just);
    const buildJust = MaybeCtorDefs(u32).Just.build;
    const FOpInfo = comptime FreeMonad(Maybe, u32).FOpInfo;
    const just_fns1 = &[_]FOpInfo{
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    };

    const pure_freem = FreeMonad(Maybe, u32).pureM(@as(u32, 33));
    const purem_fn = try freem_applicative.pure(add_pi_f64);
    var freem_fn = try purem_fn.appendValFn(
        allocator,
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    );
    defer freem_fn.deinit();
    const applied_purem = try freem_applicative.fapply(u32, f64, freem_fn, pure_freem);
    defer applied_purem.deinit();
    try testing.expectEqual(36.14, applied_purem.iter(maybeToA(f64)));
    const show_writer = try applied_purem.foldFree(nat_maybe_show, show_monad);
    defer show_writer.deinit();
    try testing.expectEqual(36.14, show_writer.a);
    try testing.expectEqualSlices(u8, "Just ", show_writer.w.items);

    const freem_a = try FreeMonad(Maybe, u32).freeM(allocator, 42, @constCast(just_fns1));
    defer freem_a.deinit();
    const applied_freem = try freem_applicative.fapply(u32, f64, freem_fn, freem_a);
    defer applied_freem.deinit();
    try testing.expectEqual(45.14, applied_freem.iter(maybeToA(f64)));
    const show1_writer = try applied_freem.foldFree(nat_maybe_show, show_monad);
    defer show1_writer.deinit();
    try testing.expectEqual(45.14, show1_writer.a);
    try testing.expectEqualSlices(u8, "Just Just Just ", show1_writer.w.items);

    const applied_purem1 = try freem_applicative.fapply(u32, f64, purem_fn, freem_a);
    defer applied_purem1.deinit();
    try testing.expectEqual(45.14, applied_purem1.iter(maybeToA(f64)));
    const show1_purem = try applied_purem1.foldFree(nat_maybe_show, show_monad);
    defer show1_purem.deinit();
    try testing.expectEqual(45.14, show1_purem.a);
    try testing.expectEqualSlices(u8, "Just Just ", show1_purem.w.items);

    const add_x_f64_lam = Add_x_f64_Lam{ ._x = 3.14 };
    var freem_lam = try freem_applicative.pure(add_x_f64_lam);
    defer freem_lam.deinit();
    const just_fns2 = &[_]FOpInfo{
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
        .{ .op_e = Nothing, .op_lam = @bitCast(buildNothing()) },
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    };
    freem_lam = try freem_lam.appendValFns(allocator, @constCast(just_fns2));
    const applied_freem1 = try freem_applicative.fapplyLam(u32, f64, freem_lam, freem_a);
    defer applied_freem1.deinit();
    try testing.expectEqual(0, applied_freem1.iter(maybeToA(f64)));
    const show2_writer = try applied_freem1.foldFree(nat_maybe_show, show_monad);
    defer show2_writer.deinit();
    try testing.expectEqual(null, show2_writer.a);
    try testing.expectEqualSlices(u8, "Just ", show2_writer.w.items);
}

test "FreeMonad(F, A) bind" {
    const allocator = testing.allocator;
    const FreeMMonad = Monad(FreeMonadImpl(Maybe));
    var freem_monad = FreeMMonad.init(.{ .allocator = allocator });

    const ShowMonadImpl = MWriterMaybeMonadImpl(ArrayListMonoidImpl(u8), ArrayList(u8));
    const ShowMonad = Monad(ShowMonadImpl);
    const array_monoid = ArrayListMonoidImpl(u8){ .allocator = allocator };
    const show_monad = ShowMonad.init(.{ .monoid_impl = array_monoid });
    const NatMaybeToShow = NatTrans(MaybeShowNatImpl);
    const nat_maybe_show = NatMaybeToShow.init(.{ .allocator = allocator });

    const MaybeCtorEnum = std.meta.DeclEnum(MaybeCtorDefs(u32));
    const Nothing: u16 = @intFromEnum(MaybeCtorEnum.Nothing);
    const buildNothing = MaybeCtorDefs(u32).Nothing.build;
    const Just: u16 = @intFromEnum(MaybeCtorEnum.Just);
    const buildJust = MaybeCtorDefs(u32).Just.build;
    const FOpInfo = comptime FreeMonad(Maybe, u32).FOpInfo;
    const just_fns1 = &[_]FOpInfo{
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    };

    const pure_freem = FreeMonad(Maybe, u32).pureM(@as(u32, 1));
    const freem_a = try FreeMonad(Maybe, u32).freeM(allocator, 2, @constCast(just_fns1));
    defer freem_a.deinit();
    const freem_b = try FreeMonad(Maybe, u32).freeM(allocator, 3, @constCast(just_fns1));
    defer freem_b.deinit();
    const freem_c = try FreeMonad(Maybe, u32).freeM(allocator, 8, @constCast(just_fns1));
    defer freem_c.deinit();

    const k_u32 = struct {
        fn f(self: *FreeMonadImpl(Maybe), a: u32) !FreeMonad(Maybe, f64) {
            const _a = if (a > 3) 0 else a;
            const just_array = switch (_a) {
                0 => &[_]FOpInfo{},
                1 => &[_]FOpInfo{
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                },
                2 => &[_]FOpInfo{
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                },
                3 => &[_]FOpInfo{
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                    .{ .op_e = Nothing, .op_lam = @bitCast(buildNothing()) },
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                },
                else => @panic("The _a is not greater than 3"),
            };
            const b = @as(f64, @floatFromInt(a)) + 3.14;

            const freem_k = if (just_array.len > 0)
                try FreeMonad(Maybe, f64).freeM(allocator, b, @constCast(just_array))
            else
                try self.pure(b);
            return freem_k;
        }
    }.f;

    const purem_binded = try freem_monad.bind(u32, f64, pure_freem, k_u32);
    defer purem_binded.deinit();
    const show_writer = try purem_binded.foldFree(nat_maybe_show, show_monad);
    defer show_writer.deinit();
    try testing.expectApproxEqRel(4.14, show_writer.a.?, std.math.floatEps(f64));
    try testing.expectEqualSlices(u8, "Just ", show_writer.w.items);

    const freem_binded = try freem_monad.bind(u32, f64, freem_a, k_u32);
    defer freem_binded.deinit();
    const show1_writer = try freem_binded.foldFree(nat_maybe_show, show_monad);
    defer show1_writer.deinit();
    try testing.expectApproxEqRel(5.14, show1_writer.a.?, std.math.floatEps(f64));
    try testing.expectEqualSlices(u8, "Just Just Just Just ", show1_writer.w.items);

    const freem_binded2 = try freem_monad.bind(u32, f64, freem_b, k_u32);
    defer freem_binded2.deinit();
    try testing.expectEqual(0, freem_binded2.iter(maybeToA(f64)));
    const show2_writer = try freem_binded2.foldFree(nat_maybe_show, show_monad);
    defer show2_writer.deinit();
    try testing.expectEqual(null, show2_writer.a);
    try testing.expectEqualSlices(u8, "Just Just Just ", show2_writer.w.items);

    const freem_binded3 = try freem_monad.bind(u32, f64, freem_c, k_u32);
    defer freem_binded3.deinit();
    const show3_writer = try freem_binded3.foldFree(nat_maybe_show, show_monad);
    defer show3_writer.deinit();
    try testing.expectApproxEqRel(11.14, show3_writer.a.?, std.math.floatEps(f64));
    try testing.expectEqualSlices(u8, "Just Just ", show3_writer.w.items);
}

test "FreeMonad(F, A) join" {
    const allocator = testing.allocator;
    const FreeMMonad = Monad(FreeMonadImpl(Maybe));
    var freem_monad = FreeMMonad.init(.{ .allocator = allocator });

    const ShowMonadImpl = MWriterMaybeMonadImpl(ArrayListMonoidImpl(u8), ArrayList(u8));
    const ShowMonad = Monad(ShowMonadImpl);
    const array_monoid = ArrayListMonoidImpl(u8){ .allocator = allocator };
    const show_monad = ShowMonad.init(.{ .monoid_impl = array_monoid });
    const NatMaybeToShow = NatTrans(MaybeShowNatImpl);
    const nat_maybe_show = NatMaybeToShow.init(.{ .allocator = allocator });

    const MaybeCtorEnum = std.meta.DeclEnum(MaybeCtorDefs(u32));
    const Nothing: u16 = @intFromEnum(MaybeCtorEnum.Nothing);
    const buildNothing = MaybeCtorDefs(u32).Nothing.build;
    const Just: u16 = @intFromEnum(MaybeCtorEnum.Just);
    const buildJust = MaybeCtorDefs(u32).Just.build;
    const FOpInfo = comptime FreeMonad(Maybe, u32).FOpInfo;
    const just_fns1 = &[_]FOpInfo{
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
        .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
    };

    const pure_freem = FreeMonad(Maybe, u32).pureM(@as(u32, 1));
    const freem_a = try FreeMonad(Maybe, u32).freeM(allocator, 2, @constCast(just_fns1));
    defer freem_a.deinit();
    const freem_b = try FreeMonad(Maybe, u32).freeM(allocator, 3, @constCast(just_fns1));
    defer freem_b.deinit();
    const freem_c = try FreeMonad(Maybe, u32).freeM(allocator, 8, @constCast(just_fns1));
    defer freem_c.deinit();

    const k_u32 = struct {
        allocator: Allocator,

        const Self = @This();
        pub fn call(self: *const Self, a: u32) !FreeMonad(Maybe, f64) {
            const _a = if (a > 3) 0 else a;
            const just_array = switch (_a) {
                0 => &[_]FOpInfo{},
                1 => &[_]FOpInfo{
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                },
                2 => &[_]FOpInfo{
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                },
                3 => &[_]FOpInfo{
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                    .{ .op_e = Nothing, .op_lam = @bitCast(buildNothing()) },
                    .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
                },
                else => @panic("The _a is not greater than 3"),
            };
            const b = @as(f64, @floatFromInt(a)) + 3.14;

            const freem_k = if (just_array.len > 0)
                try FreeMonad(Maybe, f64).freeM(self.allocator, b, @constCast(just_array))
            else
                FreeMonad(Maybe, f64).pureM(b);
            return freem_k;
        }
    }{ .allocator = allocator };

    const pure_mma = try freem_monad.fmapLam(.NewValMap, k_u32, pure_freem);
    defer pure_mma.deinit();
    const purem_joined = try freem_monad.join(f64, pure_mma);
    defer purem_joined.deinit();
    const show_writer = try purem_joined.foldFree(nat_maybe_show, show_monad);
    defer show_writer.deinit();
    try testing.expectApproxEqRel(4.14, show_writer.a.?, std.math.floatEps(f64));
    try testing.expectEqualSlices(u8, "Just ", show_writer.w.items);

    const impure_mma = try freem_monad.fmapLam(.NewValMap, k_u32, freem_a);
    defer impure_mma.deinit();
    const freem_joined = try freem_monad.join(f64, impure_mma);
    defer freem_joined.deinit();
    const show1_writer = try freem_joined.foldFree(nat_maybe_show, show_monad);
    defer show1_writer.deinit();
    try testing.expectApproxEqRel(5.14, show1_writer.a.?, std.math.floatEps(f64));
    try testing.expectEqualSlices(u8, "Just Just Just Just ", show1_writer.w.items);

    const impure_mma2 = try freem_monad.fmapLam(.NewValMap, k_u32, freem_b);
    defer impure_mma2.deinit();
    const freem_joined2 = try freem_monad.join(f64, impure_mma2);
    defer freem_joined2.deinit();
    try testing.expectEqual(0, freem_joined2.iter(maybeToA(f64)));
    const show2_writer = try freem_joined2.foldFree(nat_maybe_show, show_monad);
    defer show2_writer.deinit();
    try testing.expectEqual(null, show2_writer.a);
    try testing.expectEqualSlices(u8, "Just Just Just ", show2_writer.w.items);

    const impure_mma3 = try freem_monad.fmapLam(.NewValMap, k_u32, freem_c);
    defer impure_mma3.deinit();
    const freem_joined3 = try freem_monad.join(f64, impure_mma3);
    defer freem_joined3.deinit();
    const show3_writer = try freem_joined3.foldFree(nat_maybe_show, show_monad);
    defer show3_writer.deinit();
    try testing.expectApproxEqRel(11.14, show3_writer.a.?, std.math.floatEps(f64));
    try testing.expectEqualSlices(u8, "Just Just ", show3_writer.w.items);
}

const List = std.SinglyLinkedList;

pub fn ListCfg(comptime cfg: anytype) type {
    const Error = cfg.error_set;
    return struct {
        fn ListCtorDefs(comptime A: type) type {
            return struct {
                pub const Nil = NilLam;
                pub const Cons = ConsLam;

                // Value constructor lambdas for List
                const NilLam = extern struct {
                    lam_ctx: u64,

                    const Self = @This();
                    const NilLamCtx = void;
                    pub fn build() Self {
                        return .{ .lam_ctx = 0 };
                    }

                    pub fn deinit(self: Self) void {
                        _ = self;
                    }

                    pub fn call(self: Self) List(A) {
                        _ = self;
                        return .{ .first = null };
                    }
                };

                const ConsLam = extern struct {
                    len: u64,

                    const Self = @This();
                    const ConsLamCtx = []A;

                    pub fn build(len: u64) !Self {
                        return .{ .len = len };
                    }

                    pub fn deinit(self: Self) void {
                        _ = self;
                    }

                    pub fn call(self: *Self, as: []A) Error!List(A) {
                        assert(self.len == as.len);
                        var list: List(A) = .{ .first = null };
                        for (as) |a| {
                            const node = try cfg.allocator.create(List(A).Node);
                            node.* = .{ .next = null, .data = a };
                            list.prepend(node);
                        }
                        return list;
                    }
                };
            };
        }
    };
}

pub const ListCtxCfg =
    struct {
    allocator: Allocator,
    error_set: type,
};

fn getDefaultListCfg(allocator: Allocator) ListCtxCfg {
    return .{
        .allocator = allocator,
        .error_set = Allocator.Error,
    };
}

const ArrayListFunctorImpl = arraym.ArrayListMonadImpl;

pub const ListShowtNatImpl = struct {
    allocator: Allocator,

    const Self = @This();

    pub const F = List;
    pub const G = MWriterMaybe(ArrayList(u8));
    pub const Error = Allocator.Error;

    pub fn trans(self: Self, comptime A: type, fa: F(A)) Error!G(A) {
        var array = ArrayList(u8).init(self.allocator);
        if (fa.first) |first| {
            try array.appendSlice("[ ");
            const first_len = std.fmt.count("{any}", .{fa.first.data});
            try array.ensureUnusedCapacity(first_len);
            const first_buf = array.unusedCapacitySlice();
            std.fmt.bufPrint(first_buf, "{any}", .{fa.first.data});

            var next = first.next;
            while (next) |node| {
                const len = std.fmt.count(", {any}", .{fa.first.data});
                try array.ensureUnusedCapacity(len);
                const buf = array.unusedCapacitySlice();
                std.fmt.bufPrint(buf, ", {any}", .{fa.first.data});
                next = node.next;
            }
            try array.appendSlice(" ]");
            return .{ .a = first.data, .w = array };
        } else {
            // return empty ArrayList
            try array.appendSlice("[]");
            return .{ .a = @as(Maybe(A), null), .w = array };
        }
    }
};

fn listToA(comptime A: type) *const fn (a: List(A)) A {
    return struct {
        fn iterFn(a: List(A)) A {
            if (a.first) |first| {
                return first.data;
            } else return 0;
        }
    }.iterFn;
}

// test "FreeMonad(List, A) fmap" {
//     const allocator = testing.allocator;
//     const FreeMFunctor = Functor(FreeMonadImpl(List));
//     var freem_functor = FreeMFunctor.init(.{ .allocator = allocator });
//
//     const ShowMonadImpl = MWriterMaybeMonadImpl(ArrayListMonoidImpl(u8), ArrayList(u8));
//     const ShowMonad = Monad(ShowMonadImpl);
//     const array_monoid = ArrayListMonoidImpl(u8){ .allocator = allocator };
//     const show_monad = ShowMonad.init(.{ .monoid_impl = array_monoid });
//     const NatListToShow = NatTrans(ListShowtNatImpl);
//     const nat_list_show = NatListToShow.init(.{ .allocator = allocator });
//
//     var a: u32 = 42;
//     _ = &a;
//     // const pure_freem = .{ .pure_m = a };
//     const pure_freem = FreeMonad(List, u32).pureM(@as(u32, 42));
//     const pure_freem1 = try freem_functor.fmap(.NewValMap, add_pi_f64, pure_freem);
//     try testing.expectEqual(45.14, pure_freem1.iter(listToA(f64)));
//     const show_writer = try pure_freem1.foldFree(nat_list_show, show_monad);
//     defer show_writer.deinit();
//     try testing.expectEqual(45.14, show_writer.a);
//     try testing.expectEqualSlices(u8, "", show_writer.w.items);
//
//     const MaybeCtorEnum = std.meta.DeclEnum(MaybeCtorDefs(u32));
//     const Just: u16 = @intFromEnum(MaybeCtorEnum.Just);
//     const buildJust = MaybeCtorDefs(u32).Just.build;
//     // const Nothing: u16 = @intFromEnum(MaybeCtorEnum.Nothing);
//     const FOpInfo = comptime FreeMonad(List, u32).FOpInfo;
//     const just_fns2 = &[_]FOpInfo{
//         .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
//         .{ .op_e = Just, .op_lam = @bitCast(buildJust()) },
//     };
//     const free_maybe = try pure_freem.appendValFns(allocator, @constCast(just_fns2));
//     defer free_maybe.deinit();
//     const free_maybe1 = try freem_functor.fmap(.NewValMap, add10, free_maybe);
//     defer free_maybe1.deinit();
//     try testing.expectEqual(52, free_maybe1.iter(listToA(u32)));
//     const show1_writer = try free_maybe1.foldFree(nat_list_show, show_monad);
//     defer show1_writer.deinit();
//     try testing.expectEqual(52, show1_writer.a);
//     try testing.expectEqualSlices(u8, "Just Just ", show1_writer.w.items);
// }
