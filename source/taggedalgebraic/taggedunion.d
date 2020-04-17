/**
 * Generic tagged union and algebraic data type implementations.
 *
 * Copyright: Copyright 2015-2019, Sönke Ludwig.
 * License:   $(WEB www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Sönke Ludwig
*/
module taggedalgebraic.taggedunion;

// scheduled for deprecation
static import taggedalgebraic.visit;
alias visit = taggedalgebraic.visit.visit;

import std.algorithm.mutation : move, moveEmplace, swap;
import std.meta;
import std.range : isOutputRange;
import std.traits : EnumMembers, FieldNameTuple, Unqual, isInstanceOf;


template HelperType(T)
{
	static if (isUnitType!T) alias HelperType = Void;
	else alias HelperType = T;
}

/** Implements a generic tagged union type.

	This struct takes a `union` or `struct` declaration as an input and builds
	an algebraic data type from its fields, using an automatically generated
	`Kind` enumeration to identify which field of the union is currently used.
	Multiple fields with the same value are supported.

	For each field defined by `U` a number of convenience members are generated.
	For a given field "foo", these fields are:

	$(UL
		$(LI `static foo(value)` - returns a new tagged union with the specified value)
		$(LI `isFoo` - equivalent to `kind == Kind.foo`)
		$(LI `setFoo(value)` - equivalent to `set!(Kind.foo)(value)`)
		$(LI `getFoo` - equivalent to `get!(Kind.foo)`)
	)
*/
template TaggedUnion(U) if (is(U == union) || is(U == struct) || is(U == enum)) {
struct TaggedUnion
{
	import std.traits : FieldTypeTuple, FieldNameTuple, Largest,
		hasElaborateCopyConstructor, hasElaborateDestructor, isCopyable;
	import std.meta : templateOr;
	import std.ascii : toUpper;

	alias FieldDefinitionType = U;

	/// A type enum that identifies the type of value currently stored.
	alias Kind = UnionFieldEnum!U;

	alias FieldTypes = UnionKindTypes!Kind;
	alias fieldNames = UnionKindNames!Kind;

	static assert(FieldTypes.length > 0, "The TaggedUnions's union type must have at least one field.");
	static assert(FieldTypes.length == fieldNames.length);

	package alias FieldTypeByName(string name) = FieldTypes[__traits(getMember, Kind, name)];

	private static union Data {
		static if (!isUnitType!(FieldTypes[0]))
			FieldTypes[0] initField;
		staticMap!(HelperType, FieldTypes) field;
	}

	private {
		static if (!isUnitType!(FieldTypes[0]))
			Data m_data = { initField: FieldTypes[0].init };
		else
			Data m_data = void;
		Kind m_kind;
	}

	this(TaggedUnion other)
	{
		rawSwap(this, other);
	}

	void opAssign(TaggedUnion other)
	{
		rawSwap(this, other);
	}

	static foreach (ti; UniqueTypes!FieldTypes)
		static if(!is(FieldTypes[ti] == void))
		{
			this(FieldTypes[ti] value)
			{
				static if (isUnitType!(FieldTypes[ti]))
					set!(cast(Kind)ti)();
				else
					set!(cast(Kind)ti)(.move(value));
			}

			void opAssign(FieldTypes[ti] value)
			{
				static if (isUnitType!(FieldTypes[ti]))
					set!(cast(Kind)ti)();
				else
					set!(cast(Kind)ti)(.move(value));
			}
		}

	// disable default construction if first type is not a null/Void type
	static if (!isUnitType!(FieldTypes[0]) && __VERSION__ < 2072) {
		@disable this();
	}

	// postblit constructor
	static if (!allSatisfy!(templateOr!(isCopyable, isUnitType), FieldTypes)) {
		@disable this(this);
	} else static if (anySatisfy!(hasElaborateCopyConstructor, FieldTypes)) {
		this(this)
		{
			switch (m_kind) {
				default: break;
				foreach (i, tname; fieldNames) {
					alias T = FieldTypes[i];
					static if (hasElaborateCopyConstructor!T)
					{
						case __traits(getMember, Kind, tname):
							typeid(T).postblit(cast(void*)&trustedGet!i());
							return;
					}
				}
			}
		}
	}

	// destructor
	static if (anySatisfy!(hasElaborateDestructor, FieldTypes)) {
		~this()
		{
			final switch (m_kind) {
				foreach (i, tname; fieldNames) {
					alias T = FieldTypes[i];
					case __traits(getMember, Kind, tname):
						static if (hasElaborateDestructor!T) {
							.destroy(trustedGet!i);
						}
						return;
				}
			}
		}
	}

	/// Enables conversion or extraction of the stored value.
	T opCast(T)()
	{
		import std.conv : to;

		final switch (m_kind) {
			foreach (i, FT; FieldTypes) {
				case __traits(getMember, Kind, fieldNames[i]):
					static if (is(typeof(trustedGet!i) : T))
						return trustedGet!i;
					else static if (is(typeof(to!T(trustedGet!i)))) {
						return to!T(trustedGet!i);
					} else {
						assert(false, "Cannot cast a " ~ fieldNames[i]
								~ " value of type " ~ FT.stringof ~ " to " ~ T.stringof);
					}
			}
		}
		assert(false); // never reached
	}
	/// ditto
	T opCast(T)() const
	{
		// this method needs to be duplicated because inout doesn't work with to!()
		import std.conv : to;

		final switch (m_kind) {
			foreach (i, FT; FieldTypes) {
				case __traits(getMember, Kind, fieldNames[i]):
					static if (is(typeof(trustedGet!i) : T))
						return trustedGet!i;
					else static if (is(typeof(to!T(trustedGet!i)))) {
						return to!T(trustedGet!i);
					} else {
						assert(false, "Cannot cast a " ~ fieldNames[i]
								~ " value of type" ~ FT.stringof ~ " to " ~ T.stringof);
					}
			}
		}
		assert(false); // never reached
	}

	/// Enables equality comparison with the stored value.
	bool opEquals()(auto ref inout(TaggedUnion) other)
	inout {
		if (this.kind != other.kind) return false;

		final switch (this.kind) {
			foreach (i, fname; TaggedUnion!U.fieldNames)
				case __traits(getMember, Kind, fname):
					return trustedGet!i == other.trustedGet!i;
		}
		assert(false); // never reached
	}

	/// The type ID of the currently stored value.
	@property Kind kind() const { return m_kind; }

	static foreach (i, name; fieldNames) {
		// NOTE: using getX/setX here because using just x would be prone to
		//       misuse (attempting to "get" a value for modification when
		//       a different kind is set instead of assigning a new value)
		mixin("alias set"~pascalCase(name)~" = set!(Kind."~name~");");
		mixin("@property bool is"~pascalCase(name)~"() const { return m_kind == Kind."~name~"; }");

		static if (name[$-1] == '_') {
			mixin("alias set"~pascalCase(name[0 .. $-1])~" = set!(Kind."~name~");");
			mixin("@property bool is"~pascalCase(name[0 .. $-1])~"() const { return m_kind == Kind."~name~"; }");
		}

		static if (!isUnitType!(FieldTypes[i])) {
			mixin("alias "~name~"Value = value!(Kind."~name~");");

			// remove trailing underscore from names like "int_"
			static if (name[$-1] == '_')
				mixin("alias "~name[0 .. $-1]~"Value = value!(Kind."~name~");");

			mixin("static TaggedUnion "~name~"(FieldTypes["~i.stringof~"] value)"
				~ "{ TaggedUnion tu; tu.set!(Kind."~name~")(.move(value)); return tu; }");

			// TODO: define assignment operator for unique types
		} else {
			mixin("static @property TaggedUnion "~name~"() { TaggedUnion tu; tu.set!(Kind."~name~"); return tu; }");
		}
	}

	/** Checks whether the currently stored value has a given type.
	*/
	@property bool hasType(T)()
	const {
		static assert(staticIndexOf!(T, FieldTypes) >= 0, "Type "~T.stringof~ " not part of "~FieldTypes.stringof);

		final switch (this.kind) {
			static foreach (i, n; fieldNames) {
				case __traits(getMember, Kind, n):
					return is(FieldTypes[i] == T);
			}
		}
	}

	/** Accesses the contained value by reference.

		The specified `kind` must equal the current value of the `this.kind`
		property. Setting a different type must be done with `set` or `opAssign`
		instead.

		See_Also: `set`, `opAssign`
	*/
	@property ref inout(FieldTypes[kind]) value(Kind kind)()
	inout {
		if (this.kind != kind) {
			enum msg(.string k_is) = "Attempt to get kind "~kind.stringof~" from tagged union with kind "~k_is;
			final switch (this.kind) {
				static foreach (i, n; fieldNames)
					case __traits(getMember, Kind, n):
						assert(false, msg!n);
			}
		}
		//return trustedGet!(FieldTypes[kind]);
		return m_data.fields[kind];
	}


	/** Accesses the contained value by reference.

		The specified type `T` must equal the type of the currently set value.
		Setting a different type must be done with `set` or `opAssign` instead.

		See_Also: `set`, `opAssign`
	*/
	@property ref inout(T) value(T)() inout
	{
		static assert(staticIndexOf!(T, FieldTypes) >= 0, "Type "~T.stringof~ " not part of "~FieldTypes.stringof);

		final switch (this.kind) {
			static foreach (i, n; fieldNames) {
				case __traits(getMember, Kind, n):
					static if (is(FieldTypes[i] == T))
						return trustedGet!i;
					else assert(false, "Attempting to get type "~T.stringof
						~ " from a TaggedUnion with type "
						~ FieldTypes[__traits(getMember, Kind, n)].stringof);
			}
		}
	}

	/** Sets a new value of the specified `kind`.
	*/
	ref FieldTypes[kind] set(Kind kind)(FieldTypes[kind] value)
		if (!isUnitType!(FieldTypes[kind]))
	{
		if (m_kind != kind) {
			destroy(this);
			m_data.field[kind].moveEmplace(value);
		} else {
			rawSwap(trustedGet!kind, value);
		}
		m_kind = kind;

		return trustedGet!kind;
	}

	/** Sets a `void` value of the specified kind.
	*/
	void set(Kind kind)()
		if (isUnitType!(FieldTypes[kind]))
	{
		if (m_kind != kind) {
			destroy(this);
		}
		m_kind = kind;
	}

	/** Converts the contained value to a string.

		The format output by this method is "(kind: value)", where "kind" is
		the enum name of the currently stored type and "value" is the string
		representation of the stored value.
	*/
	void toString(W)(ref W w) const
		if (isOutputRange!(W, char))
	{
		import std.range.primitives : put;
		toString(s => put(w, s));
	}
	/// ditto
	void toString(scope void delegate(const(char)[]) sink)
	const {
		import std.conv : text;
		import std.format : FormatSpec, formatValue;

		final switch (m_kind) {
			foreach (i, v; EnumMembers!Kind) {
				case v:
					enum vstr = text(v);
					static if (isUnitType!(FieldTypes[i])) sink(vstr);
					else {
						// NOTE: using formatValue instead of formattedWrite
						//       because formattedWrite does not work for
						//       non-copyable types
						enum prefix = "(" ~ vstr ~ ": ";
						enum suffix = ")";
						sink(prefix);
						FormatSpec!char spec;
						sink.formatValue(value!v, spec);
						sink(suffix);
					}
					break;
			}
		}
	}


	package @trusted @property ref trustedGet(size_t i)() inout { return m_data.field[i]; }
}
}

///
@safe nothrow unittest {
	union Kinds {
		int count;
		string text;
	}
	alias TU = TaggedUnion!Kinds;

	// default initialized to the first field defined
	TU tu;
	assert(tu.kind == TU.Kind.count);
	assert(tu.isCount); // qequivalent to the line above
	assert(!tu.isText);
	assert(tu.value!(TU.Kind.count) == int.init);

	// set to a specific count
	tu.setCount(42);
	assert(tu.isCount);
	assert(tu.countValue == 42);
	assert(tu.value!(TU.Kind.count) == 42);
	assert(tu.value!int == 42); // can also get by type
	assert(tu.countValue == 42);

	// assign a new tagged algebraic value
	tu = TU.count(43);

	// test equivalence with other tagged unions
	assert(tu == TU.count(43));
	assert(tu != TU.count(42));
	assert(tu != TU.text("hello"));

	// modify by reference
	tu.countValue++;
	assert(tu.countValue == 44);

	// set the second field
	tu.setText("hello");
	assert(!tu.isCount);
	assert(tu.isText);
	assert(tu.kind == TU.Kind.text);
	assert(tu.textValue == "hello");

	// unique types can also be directly constructed
	tu = TU(12);
	assert(tu.countValue == 12);
	tu = TU("foo");
	assert(tu.textValue == "foo");
}

///
@safe nothrow unittest {
	// Enum annotations supported since DMD 2.082.0. The mixin below is
	// necessary to keep the parser happy on older versions.
	static if (__VERSION__ >= 2082) {
		alias myint = int;
		// tagged unions can be defined in terms of an annotated enum
		mixin(q{enum E {
			none,
			@string text
		}});

		alias TU = TaggedUnion!E;
		static assert(is(TU.Kind == E));

		TU tu;
		assert(tu.isNone);
		assert(tu.kind == E.none);

		tu.setText("foo");
		assert(tu.kind == E.text);
		assert(tu.textValue == "foo");
	}
}

unittest { // test for name clashes
	union U { .string string; }
	alias TU = TaggedUnion!U;
	TU tu;
	tu = TU.string("foo");
	assert(tu.isString);
	assert(tu.stringValue == "foo");
}

unittest { // test woraround for Phobos issue 19696
	struct T {
		struct F { int num; }
		alias Payload = TaggedUnion!F;
		Payload payload;
		alias payload this;
	}

	struct U {
		T t;
	}

	alias TU = TaggedUnion!U;
	static assert(is(TU.FieldTypes[0] == T));
}

unittest { // non-copyable types
	import std.traits : isCopyable;

	struct S { @disable this(this); }
	struct U {
		int i;
		S s;
	}
	alias TU = TaggedUnion!U;
	static assert(!isCopyable!TU);

	auto tu = TU(42);
	tu.setS(S.init);
}

unittest { // alignment
	union S1 { int v; }
	union S2 { ulong v; }
	union S3 { void* v; }

	// sanity check for the actual checks - this may differ on non-x86 architectures
	static assert(S1.alignof == 4);
	static assert(S2.alignof == 8);
	version (D_LP64) static assert(S3.alignof == 8);
	else static assert(S3.alignof == 4);

	// test external struct alignment
	static assert(TaggedUnion!S1.alignof == 4);
	static assert(TaggedUnion!S2.alignof == 8);
	version (D_LP64) static assert(TaggedUnion!S3.alignof == 8);
	else static assert(TaggedUnion!S3.alignof == 4);

	// test internal struct alignment
	TaggedUnion!S1 s1;
	assert((cast(ubyte*)&s1.vValue() - cast(ubyte*)&s1) % 4 == 0);
	TaggedUnion!S1 s2;
	assert((cast(ubyte*)&s2.vValue() - cast(ubyte*)&s2) % 8 == 0);
	TaggedUnion!S1 s3;
	version (D_LP64) assert((cast(ubyte*)&s3.vValue() - cast(ubyte*)&s3) % 8 == 0);
	else assert((cast(ubyte*)&s3.vValue() - cast(ubyte*)&s3) % 4 == 0);
}

unittest { // toString
	import std.conv : to;

	static struct NoCopy {
		@disable this(this);
		string toString() const { return "foo"; }
	}

	union U { Void empty; int i; NoCopy noCopy; }
	TaggedUnion!U val;
	assert(val.to!string == "empty");
	val.setI(42);
	assert(val.to!string == "(i: 42)");
	val.setNoCopy(NoCopy.init);
	assert(val.to!string == "(noCopy: foo)");
}

unittest { // null members should be assignable
	union U { int i; typeof(null) Null; }
	TaggedUnion!U val;
	val = null;
	assert(val.kind == val.Kind.Null);
	val = TaggedUnion!U(null);
	assert(val.kind == val.Kind.Null);
}

unittest { // make sure field names don't conflict with function names
	union U { int to; int move; int swap; }
	TaggedUnion!U val;
	val.setMove(1);
}

unittest { // support trailing underscores properly
	union U {
		int int_;
	}
	TaggedUnion!U val;

	val = TaggedUnion!U.int_(10);
	assert(val.int_Value == 10);
	assert(val.intValue == 10);
	assert(val.isInt_);
	assert(val.isInt);
	val.setInt_(20);
	val.setInt(20);
	assert(val.intValue == 20);
}

enum isUnitType(T) = is(T == Void) || is(T == void) || is(T == typeof(null));


private string pascalCase(string camel_case)
{
	if (!__ctfe) assert(false);
	import std.ascii : toUpper;
	return camel_case[0].toUpper ~ camel_case[1 .. $];
}

/** Maps a kind enumeration value to the corresponding field type.

	`kind` must be a value of the `TaggedAlgebraic!T.Kind` enumeration.
*/
template TypeOf(alias kind)
	if (is(typeof(kind) == enum))
{
	import std.traits : FieldTypeTuple, TemplateArgsOf;
	import std.typecons : ReplaceType;

	static if (isInstanceOf!(UnionFieldEnum, typeof(kind))) {
		alias U = TemplateArgsOf!(typeof(kind));
		alias FT = FieldTypeTuple!U[kind];
	} else {
		alias U = typeof(kind);
		alias Types = UnionKindTypes!(typeof(kind));
		alias uda = AliasSeq!(__traits(getAttributes, kind));
		static if (uda.length == 0) alias FT = void;
		else alias FT = uda[0];
	}

	// NOTE: ReplaceType has issues with certain types, such as a class
	//       declaration like this: class C : D!C {}
	//       For this reason, we test first if it compiles and only then use it.
	//       It also replaces a type with the contained "alias this" type under
	//       certain conditions, so we make a second check to see heuristically
	//       if This is actually present in FT
	//
	//       Phobos issues: 19696, 19697
	static if (is(ReplaceType!(This, U, FT)) && !is(ReplaceType!(This, void, FT)))
		alias TypeOf = ReplaceType!(This, U, FT);
	else alias TypeOf = FT;
}

///
unittest {
	static struct S {
		int a;
		string b;
		string c;
	}
	alias TU = TaggedUnion!S;

	static assert(is(TypeOf!(TU.Kind.a) == int));
	static assert(is(TypeOf!(TU.Kind.b) == string));
	static assert(is(TypeOf!(TU.Kind.c) == string));
}

unittest {
	struct S {
		TaggedUnion!This[] test;
	}
	alias TU = TaggedUnion!S;

	TypeOf!(TU.Kind.test) a;

	static assert(is(TypeOf!(TU.Kind.test) == TaggedUnion!S[]));
}


/// Convenience type that can be used for union fields that have no value (`void` is not allowed).
struct Void {}

/** Special type used as a placeholder for `U` within the definition of `U` to
	enable self-referential types.

	Note that this is recognized only if used as the first argument to a
	template type.
*/
struct This { Void nothing; }

///
unittest {
	union U {
		TaggedUnion!This[] list;
		int number;
		string text;
	}
	alias Node = TaggedUnion!U;

	auto n = Node([Node(12), Node("foo")]);
	assert(n.isList);
	assert(n.listValue == [Node(12), Node("foo")]);
}

package template UnionFieldEnum(U)
{
	static if (is(U == enum)) alias UnionFieldEnum = U;
	else {
		import std.array : join;
		import std.traits : FieldNameTuple;
		mixin("enum UnionFieldEnum { " ~ [FieldNameTuple!U].join(", ") ~ " }");
	}
}

deprecated alias TypeEnum(U) = UnionFieldEnum!U;

package alias UnionKindTypes(FieldEnum) = staticMap!(TypeOf, EnumMembers!FieldEnum);
package alias UnionKindNames(FieldEnum) = AliasSeq!(__traits(allMembers, FieldEnum));

package template UniqueTypes(Types...) {
	template impl(size_t i) {
		static if (i < Types.length) {
			alias T = Types[i];
			static if (staticIndexOf!(T, Types) == i && staticIndexOf!(T, Types[i+1 .. $]) < 0)
				alias impl = AliasSeq!(i, impl!(i+1));
			else alias impl = AliasSeq!(impl!(i+1));
		} else alias impl = AliasSeq!();
	}
	alias UniqueTypes = impl!0;
}

package template AmbiguousTypes(Types...) {
	template impl(size_t i) {
		static if (i < Types.length) {
			alias T = Types[i];
			static if (staticIndexOf!(T, Types) == i && staticIndexOf!(T, Types[i+1 .. $]) >= 0)
				alias impl = AliasSeq!(i, impl!(i+1));
			else alias impl = impl!(i+1);
		} else alias impl = AliasSeq!();
	}
	alias AmbiguousTypes = impl!0;
}

/// Computes the minimum alignment necessary to align all types correctly
private size_t commonAlignment(TYPES...)()
{
	import std.numeric : gcd;

	size_t ret = 1;
	foreach (T; TYPES)
		ret = (T.alignof * ret) / gcd(T.alignof, ret);
	return ret;
}

unittest {
	align(2) struct S1 { ubyte x; }
	align(4) struct S2 { ubyte x; }
	align(8) struct S3 { ubyte x; }

	static if (__VERSION__ > 2076) { // DMD 2.076 ignores the alignment
		assert(commonAlignment!S1 == 2);
		assert(commonAlignment!S2 == 4);
		assert(commonAlignment!S3 == 8);
		assert(commonAlignment!(S1, S3) == 8);
		assert(commonAlignment!(S1, S2, S3) == 8);
		assert(commonAlignment!(S2, S2, S1) == 4);
	}
}

// std.algorithm.mutation.swap sometimes fails to compile due to
// internal errors in hasElaborateAssign!T/isAssignable!T. This is probably
// caused by cyclic dependencies. However, there is no reason to do these
// checks in this context, so we just directly move the raw memory.
package void rawSwap(T)(ref T a, ref T b)
@trusted {
	void[T.sizeof] tmp = void;
	void[] ab = (cast(void*)&a)[0 .. T.sizeof];
	void[] bb = (cast(void*)&b)[0 .. T.sizeof];
	tmp[] = ab[];
	ab[] = bb[];
	bb[] = tmp[];
}
