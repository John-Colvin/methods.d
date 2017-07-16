// Written in the D programming language.

/++
 This module implements fast open multi-_methods.

 Open _methods are like virtual functions, except that they are free functions,
 living outside of any class. Multi-_methods can take into account the dynamic
 types of more than one argument to select the most specialized variant of the
 function.

 This implementation uses compressed dispatch tables to deliver a performance
 similar to ordinary virtual function calls, while minimizing the size of the
 dispatch tables in presence of multiple virtual arguments.

 $(B CAVEAT): this module uses the deprecated `deallocator` field in the
 `ClassInfo` structure to store a pointer similar to a `vptr` . It is thus
 incompatible with classes that define a `delete` member, and with modules
 that use this field for their own purpose.

 Synopsis of methods:
---

import methods; // import lib
mixin(registerMethods); // once per module - don't forget!

interface  Animal {}
class Dog : Animal {}
class Pitbull : Dog {}
class Cat : Animal {}
class Dolphin : Animal {}

// open method with single argument <=> virtual function "from outside"
string kick(virtual!Animal);

@method // implement 'kick' for dogs
string _kick(Dog x) // note the underscore
{
  return "bark";
}

@method("kick") // use a different name for specialization
string notGoodIdea(Pitbull x)
{
  return next!kick(x) ~ " and bite"; // aka call 'super'
}

// multi-method
string meet(virtual!Animal, virtual!Animal);

// 'meet' implementations
@method
string _meet(Animal, Animal)
{
  return "ignore";
}

@method
string _meet(Dog, Dog)
{
  return "wag tail";
}

@method
string _meet(Dog, Cat)
{
  return "chase";
}

void main()
{
  updateMethods(); // once per process - don't forget!

  import std.stdio;

  Animal rex = new Pitbull, snoopy = new Dog;
  writeln("kick snoopy: ", kick(snoopy)); // bark
  writeln("kick rex: ", kick(rex)); // bark and bite

  Animal felix = new Cat, flipper = new Dolphin;
  writeln("rex meets felix: ", meet(rex, felix)); // chase
  writeln("rex meets snoopy: ", meet(rex, snoopy)); // wag tail
  writeln("rex meets flipper: ", meet(rex, flipper)); // ignore
}
---

 Copyright: Copyright Jean-Louis Leroy 2017

 License:   $(LINK2 http://boost.org/LICENSE_1_0.txt, Boost License 1.0).

 Authors:   Jean-Louis Leroy 2017
+/

module methods;

import std.traits;
import std.format;
import std.meta;
import std.algorithm;
import std.algorithm.iteration;
import std.range;
import std.container.rbtree;
import std.bitmanip;

version (explain) {
  import std.stdio;
}

// ============================================================================
// Pubic stuff

/++
 Mark a parameter as virtual, and declare a method.

 A new function is introduced in the current scope. It has the same name as the
 declared method; its parameter consists in the declared parameters, stripped
 from the `virtual!` qualifier. Calls to this function resolve to the most
 specific method that matches the arguments.

 The rules for determining the most specific function are exactly the same as
 those that guide the resolution of function calls in presence of overloads -
 only the resolution happens at run time, taking into account the argument's
 $(I dynamic) type. In contrast, the normal function overload resolution is a
 compile time mechanism that takes into account the $(I static) type of the
 arguments.

 Throws:
 `UndefinedCallError` if no method is compatible with the argument list$.$(BR)
 `AmbiguousCallError` if several compatible  methods exist but none of
 them is more specific than all the others$.$(BR)

 Examples:
 ---
 Matrix times(double, virtual!Matrix);
 string fight(virtual!Character, virtual!Creature, virtual!Device);

 Matrix a = new DiagonalMatrix(...);
 auto result = times(2, a);

 fight(player, room.guardian, bag[item]);
 ---
 +/

class virtual(T)
{
}

/++
 Used as an attribute: add an override to a method.

 If called without argument, the function name must consist in a method name,
 prefixed with an underscore. The function is added to the method as a
 specialization.

 If called with a string argument, it is interpreted as the name of the method
 to specialize. The function name can then be any valid identifier. This is
 useful to allow one override to call a specific override without going through
 the dynamic dispatch mechanism.

 Examples:
 ---
 @method
 string _fight(Character x, Creature y, Axe z)
 {
   ...
 }

 @method("times")
 Matrix doubleTimesDiagonal(double a, immutable(DiagonalMatrix) b)
 {
   ...
 }
 ---

+/

struct method
{
  this(string name)
  {
    id = name;
  }

  string id;
}

/++ Call the _next most specialized override if it exists. In other words, call
 the override that would have been called if this one had not been defined.

 Throws:
 `UndefinedCallError` if the current method does not override any other overrides.$(BR)
 `AmbiguousCallError` if more than one '_next' overrides exist but none of
 them is more specific than all the others.

 Examples:
 ---
void inspect(virtual!Vehicle, virtual!Inspector);

@method
void _inspect(Vehicle v, Inspector i)
{
  writeln("Inspect vehicle.");
}

@method
void _inspect(Car v, Inspector i)
{
  next!inspect(v, i);
  writeln("Inspect seat belts.");
}

@method
void _inspect(Car v, StateInspector i)
{
  next!inspect(v, i);
  writeln("Check insurance.");
}

...

Vehicle car = new Car;
Inspector inspector = new StateInspector;
inspect(car, inspector); // Inspect vehicle. Inspect seat belts. Check insurance.
 ---
+/

auto next(alias F, T...)(T args)
{
  alias M = typeof(F(MethodTag.init, T.init));
  return M.nextPtr!(T)(args);
}

/++ Used as a string mixin: register the methods declaration and definitions in
 the current module.

 Examples:
 ---
import methods;
mixin(registerMethods);
 ---
 +/

string registerMethods(string moduleName = __MODULE__)
{
  return format("mixin(_registerMethods!%s);\nmixin _registerSpecs!%s;\n",
                moduleName, moduleName);
}

/++
 Update the runtime dispatch tables. Must be called once before calling any method. Typically this is done at the beginning of `main`.
 +/

void updateMethods()
{
  Runtime rt;
  rt.update();
}

/++
 The base class of all the exceptions thrown by this module.
+/

class MethodError : Error
{
  this(string msg, Throwable next = null)
  {
    super(msg, next);
  }
}

/++
 Thrown if no override matches the argument list.
+/

class UndefinedCallError : MethodError
{
  this(string method, Throwable next = null)
  {
    super("this call to '" ~ method ~ "' is not implemented", next);
  }
}

/++ Thrown if more than one override matches the argument list, but none is
 more specific than all the others.
+/

class AmbiguousCallError : MethodError
{
  this(string method, Throwable next = null)
  {
    super("this call to '" ~ method ~ "' is ambiguous", next);
  }
}

// ============================================================================
// Private parts. This doesn't exist. If you believe it does and use it, on
// your head be it.

const bool IsVirtual(T) = false;
const bool IsVirtual(T : virtual!U, U) = true;

alias VirtualType(T : virtual!U, U) = U;

static template CallParams(T...)
{
  static if (T.length == 0) {
    alias CallParams = AliasSeq!();
  } else {
    static if (IsVirtual!(T[0])) {
      alias CallParams = AliasSeq!(VirtualType!(T[0]), CallParams!(T[1..$]));
    } else {
      alias CallParams = AliasSeq!(T[0], CallParams!(T[1..$]));
    }
  }
}

template castArgs(T...)
{
  import std.typecons : tuple;
  static if (T.length) {
    template To(S...)
    {
      auto arglist(A...)(A args) {
        alias QP = T[0];
        static if (IsVirtual!QP) {
          static if (is(VirtualType!QP == class)) {
            auto arg = cast(S[0]) cast(void*) args[0];
          } else {
            static assert(is(VirtualType!QP == interface),
                             "virtual argument must be a class or an interface");
            auto arg = cast(S[0]) args[0];
          }
        } else {
          auto arg = args[0];
        }
        return
          tuple(arg,
                castArgs!(T[1..$]).To!(S[1..$]).arglist(args[1..$]).expand);
      }
    }
  } else {
    template To(X...)
    {
      auto arglist() {
        return tuple();
      }
    }
  }
}

struct Method(string id, R, T...)
{
  import std.stdio;
  import std.traits;
  import std.meta;

  alias QualParams = T;
  alias Params = CallParams!T;
  alias R function(Params) Spec;
  alias ReturnType = R;

  static __gshared Runtime.MethodInfo info;

  static R throwUndefined(T...)
  {
    throw new UndefinedCallError(id);
  }

  static R throwAmbiguousCall(T...)
  {
    throw new AmbiguousCallError(id);
  }

  static Method discriminator(MethodTag, CallParams!T);

  static auto dispatcher(CallParams!T args)
  {
    int dim = 0;
    int offset = 0;
    int slot = 0;
    alias Word = Runtime.Word;
    assert(info.dispatchTable, "updateMethods not called");
    assert(info.strides);
    version (traceCalls) {
      writefln("dt = %s", info.dispatchTable);
    }
    void* dp;
    foreach (int argIndex, QP; QualParams) {
      static if (IsVirtual!QP) {
        assert(args[argIndex], "null passed as virtual argument");
        const (Word)* indexes;
        static if (is(VirtualType!QP == class)) {
          indexes = cast(const Word*) args[argIndex].classinfo.deallocator;
        } else {
          static assert(is(VirtualType!QP == interface));
          Object o = cast(Object)
            (cast(void*) args[argIndex] - (cast(Interface*) **cast(void***) args[argIndex]).offset);
          indexes = cast(const Word*) o.classinfo.deallocator;
        }
        assert(indexes);
        version (traceCalls) {
          writefln("%*sdim = %d, class = %s, indexes = %s, slot = %d"
                   ~ ", info.slots[slot] = %s"
                   ~ ", indexes[info.slots[slot]] = %d"
                   ~ ", info.strides[dim].i = %d"
                   , dim * 2, "", dim, typeid(args[argIndex]), indexes, slot
                   , info.slots[slot]
                   , indexes[info.slots[slot]]
                   , info.strides[dim].i
                   );
        }
        offset = offset + indexes[info.slots[slot].i].i * info.strides[dim].i;
        ++dim;
        ++slot;
      }
    }
    auto pf = cast(Spec) info.dispatchTable[offset].p;
    assert(pf);
    version (traceCalls) {
      writefln("offset = %d", offset);
      writefln("pf = %s", pf);
    }
    static if (is(R == void)) {
      pf(args);
    } else {
      return pf(args);
    }
  }

  static this() {
    info.name = id;
    info.throwAmbiguousCall = &throwAmbiguousCall;
    info.throwUndefined = &throwUndefined;
    foreach (QP; QualParams) {
      int i = 0;
      static if (IsVirtual!QP) {
        info.vp ~= VirtualType!(QP).classinfo;
      }
    }
    Runtime.register(&info);
  }

  static class Specialization(alias fun)
  {
    alias Parameters!fun SpecParams;
    static this() {
      auto wrapper = function ReturnType(Params args) {
        static if (is(ReturnType == void)) {
          fun(castArgs!(T).To!(SpecParams).arglist(args).expand);
        } else {
          return fun(castArgs!(T).To!(SpecParams).arglist(args).expand);
        }
      };

      static __gshared Runtime.SpecInfo si;
      si.pf = cast(void*) wrapper;


      foreach (i, QP; QualParams) {
        static if (IsVirtual!QP) {
          si.vp ~= SpecParams[i].classinfo;
        }
      }
      info.specInfos ~= &si;
      si.nextPtr = cast(void**) &nextPtr!SpecParams;
    }
  }

  static Spec nextPtr(T...) = null;
}

struct MethodTag { }

struct Runtime
{
  union Word
  {
    void* p;
    int i;
  }

  struct MethodInfo
  {
    string name;
    ClassInfo[] vp;
    SpecInfo*[] specInfos;
    Word* slots;
    Word* strides;
    Word* dispatchTable;
    void* throwAmbiguousCall;
    void* throwUndefined;
  }

  struct SpecInfo
  {
    void* pf;
    ClassInfo[] vp;
    void** nextPtr;
  }

  struct Method
  {
    MethodInfo* info;
    Class*[] vp;
    Spec*[] specs;

    int[] slots;
    int[] strides;
    void*[] dispatchTable;
    GroupMap firstDim;

    auto toString() const
    {
      return format("%s(%s)", info.name, vp.map!(c => c.name).join(", "));
    }
  }

  struct Spec
  {
    SpecInfo* info;
    Class*[] params;

    auto toString() const
    {
      return format("(%s)", params.map!(c => c.name).join(", "));
    }
  }

  struct Param
  {
    Method* method;
    int param;

    auto toString() const
    {
      return format("%s#%d", *method, param);
    }
  }

  struct Class
  {
    ClassInfo info;
    Class*[] directBases;
    Class*[] directDerived;
    Class*[Class*] conforming;
    Param[] methodParams;
    int nextSlot = 0;
    int firstUsedSlot = -1;

    @property auto name() const
    {
      return info.name.split(".")[$ - 1];
    }

    @property auto isClass()
    {
      return info.base is Object.classinfo || info.base !is null;
    }
  }

  alias Registry = MethodInfo*[MethodInfo*];

  static __gshared Registry methodInfos;
  static __gshared Word[] giv; // Global Index Vector
  static __gshared Word[] gdv; // Global Dispatch Vector
  Method*[] methods;
  Class*[ClassInfo] classMap;
  Class*[] classes;

  static void register(MethodInfo* mi)
  {
    version (explain) {
      writefln("registering %s", *mi);
    }

    methodInfos[mi] = mi;
  }

  void seed()
  {
    version (explain) {
      write("Seeding...\n ");
    }

    Class* upgrade(ClassInfo ci)
    {
      Class* c;
      if (ci in classMap) {
        c = classMap[ci];
      } else {
        c = classMap[ci] = new Class(ci);
        version (explain) {
          writef(" %s", c.name);
        }
      }
      return c;
    }

    foreach (mi; methodInfos.values) {
      auto m = new Method(mi);
      methods ~= m;

      foreach (int i, ci; mi.vp) {
        auto c = upgrade(ci);
        m.vp ~= c;
        c.methodParams ~= Runtime.Param(m, i);
      }

      m.specs = mi.specInfos.map!
        (si => new Spec(si,
                        si.vp.map!
                        (ci => upgrade(ci)).array)).array;

    }

    version (explain) {
      writeln();
    }
  }

  bool scoop(ClassInfo ci)
  {
    bool hasMethods;

    foreach (i; ci.interfaces) {
      if (scoop(i.classinfo)) {
        hasMethods = true;
      }
    }

    if (ci.base) {
      if (scoop(ci.base)) {
        hasMethods = true;
      }
    }

    if (ci in classMap) {
      hasMethods = true;
    } else if (hasMethods) {
      if (ci !in classMap) {
        auto c = classMap[ci] = new Class(ci);
        version (explain) {
          writefln("  %s", c.name);
        }
      }
    }

    return hasMethods;
  }

  void initClasses()
  {
    foreach (ci, c; classMap) {
      foreach (i; ci.interfaces) {
        if (i.classinfo in classMap) {
          auto b = classMap[i.classinfo];
          c.directBases ~= b;
          b.directDerived ~= c;
        }
      }
      if (ci.base in classMap) {
        auto b = classMap[ci.base];
        c.directBases ~= b;
        b.directDerived ~= c;
      }
    }
  }

  void layer()
  {
    version (explain) {
      writefln("Layering...");
    }

    auto v = classMap.values.filter!(c => c.directBases.empty).array;
    auto m = assocArray(zip(v, v));

    while (!v.empty) {
      version (explain) {
        writefln("  %s", v.map!(c => c.name).join(" "));
      }

      v.sort!((a, b) => cmp(a.name, b.name) < 0);
      classes ~= v;

      foreach (c; v) {
        classMap.remove(c.info);
      }

      v = classMap.values.filter!(c => c.directBases.all!(b => b in m)).array;

      foreach (c; v) {
        m[c] = c;
      }
    }
  }

  void calculateInheritanceRelationships()
  {
    auto rclasses = classes.dup;
    reverse(rclasses);

    foreach (c; rclasses) {
      c.conforming[c] = c;
      foreach (d; c.directDerived) {
        c.conforming[d] = d;
        foreach (dc; d.conforming) {
          c.conforming[dc] = dc;
        }

      }
    }
  }

  void allocateSlots()
  {
    version (explain) {
      writeln("Allocating slots...");
    }

    foreach (c; classes) {
      if (!c.methodParams.empty) {
        version (explain) {
          writefln("  %s...", c.name);
        }

        foreach (mp; c.methodParams) {
          int slot = c.nextSlot++;

          version (explain) {
            writef("    for %s: allocate slot %d\n    also in", mp, slot);
          }

          if (mp.method.slots.length <= mp.param) {
            mp.method.slots.length = mp.param + 1;
          }

          mp.method.slots[mp.param] = slot;

          if (c.firstUsedSlot == -1) {
            c.firstUsedSlot = slot;
          }

          bool [Class*] visited;
          visited[c] = true;

          foreach (d; c.directDerived) {
            allocateSlotDown(d, slot, visited);
          }

          version (explain) {
            writeln();
          }
        }
      }
    }

    version (explain) {
      writeln("Initializing the global index vector...");
    }

    giv.length =
      classes.filter!(c => c.isClass).map!(c => c.nextSlot - c.firstUsedSlot).sum
      + methods.map!(m => m.vp.length).sum;

    // dmd doesn't like this: giv.fill(-1);

    Word* sp = giv.ptr;

    version (explain) {
      writefln("  giv size: %d", giv.length);
      writeln("  slots:");
    }

    foreach (m; methods) {
      version (explain) {
        writefln("    %s %02d-%02d %s",
                 sp, sp - giv.ptr, sp - giv.ptr + m.vp.length, *m);
      }
      m.info.slots = sp;
      foreach (slot; m.slots) {
        sp++.i = slot;
      }
    }

    version (explain) {
      writeln("  indexes:");
    }

    foreach (c; classes) {
      if (c.isClass) {
        version (explain) {
          writefln("    %s %02d-%02d %s",
                   sp, c.firstUsedSlot, c.nextSlot, c.name);
        }
        c.info.deallocator = cast(Word*) sp;
        sp += c.nextSlot - c.firstUsedSlot;
      }
    }
  }

  void allocateSlotDown(Class* c, int slot, bool[Class*] visited)
  {
    if (c in visited)
      return;

    version (explain) {
      writef(" %s", c.name);
    }

    visited[c] = true;

    assert(slot >= c.nextSlot);

    c.nextSlot = slot + 1;

    if (c.firstUsedSlot == -1) {
      c.firstUsedSlot = slot;
    }

    foreach (b; c.directBases) {
      allocateSlotUp(b, slot, visited);
    }

    foreach (d; c.directDerived) {
      allocateSlotDown(d, slot, visited);
    }
  }

  void allocateSlotUp(Class* c, int slot, bool[Class*] visited)
  {
    if (c in visited)
      return;

    version (explain) {
      writef(" %s", c.name);
    }

    visited[c] = true;

    assert(slot >= c.nextSlot);

    c.nextSlot = slot + 1;

    if (c.firstUsedSlot == -1) {
      c.firstUsedSlot = slot;
    }

    foreach (d; c.directBases) {
      allocateSlotUp(d, slot, visited);
    }
  }

  static bool isMoreSpecific(Spec* a, Spec* b)
  {
    bool result = false;

    for (int i = 0; i < a.params.length; i++) {
      if (a.params[i] !is b.params[i]) {
        if (a.params[i] in b.params[i].conforming) {
          result = true;
        } else if (b.params[i] in a.params[i].conforming) {
          return false;
        }
      }
    }

    return result;
  }

  static Spec*[] best(Spec*[] candidates) {
    Spec*[] best;

    foreach (spec; candidates) {
      for (int i = 0; i != best.length; ) {
        if (isMoreSpecific(spec, best[i])) {
          best.remove(i);
          best.length -= 1;
        } else if (isMoreSpecific(best[i], spec)) {
          spec = null;
          break;
        } else {
          ++i;
        }
      }

      if (spec) {
        best ~= spec;
      }
    }

    return best;
  }

  alias GroupMap = Class*[][BitArray];

  void buildTable(Method* m, ulong dim, GroupMap[] groups, BitArray candidates)
  {
    int groupIndex = 0;

    foreach (mask, group; groups[dim]) {
      if (dim == 0) {
        auto finalMask = candidates & mask;
        Spec*[] applicable;

        foreach (i, spec; m.specs) {
          if (finalMask[i]) {
            applicable ~= spec;
          }
        }

        version (explain) {
          writefln("%*s    dim %d group %d (%s): select best of %s",
                   (m.vp.length - dim) * 2, "",
                   dim, groupIndex,
                   group.map!(c => c.name).join(", "),
                   applicable.map!(spec => spec.toString).join(", "));
        }

        auto specs = best(applicable);

        if (specs.length > 1) {
          m.dispatchTable ~= m.info.throwAmbiguousCall;
        } else if (specs.empty) {
          m.dispatchTable ~= m.info.throwUndefined;
        } else {
          m.dispatchTable ~= specs[0].info.pf;

          version (explain) {
            writefln("%*s      %s: pf = %s",
                     (m.vp.length - dim) * 2, "",
                     specs.map!(spec => spec.toString).join(", "),
                     specs[0].info.pf);
          }
        }
      } else {
        version (explain) {
          writefln("%*s    dim %d group %d (%s)",
                   (m.vp.length - dim) * 2, "",
                   dim, groupIndex,
                   group.map!(c => c.name).join(", "));
        }
        buildTable(m, dim - 1, groups, candidates & mask);
      }
      ++groupIndex;
    }
  }

  void buildTables()
  {
    foreach (m; methods) {
      version (explain) {
        writefln("Building dispatch table for %s", *m);
      }

      auto dims = m.vp.length;
      GroupMap[] groups;
      groups.length = dims;

      foreach (int dim, vp; m.vp) {
        version (explain) {
          writefln("  make groups for param #%s, class %s", dim, vp.name);
        }

        foreach (conforming; vp.conforming) {
          if (conforming.isClass) {
            version (explain) {
              writefln("    specs applicable to %s", conforming.name);
            }

            BitArray mask;
            mask.length = m.specs.length;

            foreach (int specIndex, spec; m.specs) {
              if (conforming in spec.params[dim].conforming) {
                version (explain) {
                  writefln("      %s", *spec);
                }
                mask[specIndex] = 1;
              }
            }

            version (explain) {
              writefln("      bit mask = %s", mask);
            }

            if (mask in groups[dim]) {
              version (explain) {
                writefln("      add class %s to existing group", conforming.name, mask);
              }
              groups[dim][mask] ~= conforming;
            } else {
              version (explain) {
                writefln("      create new group for %s", conforming.name);
              }
              groups[dim][mask] = [ conforming ];
            }
          }
        }
      }

      int stride = 1;
      m.strides.length = dims;

      foreach (int dim, vp; m.vp) {
        version (explain) {
          writefln("    stride for dim %s = %s", dim, stride);
        }
        m.strides[dim] = stride;
        stride *= groups[dim].length;
      }

      BitArray none;
      none.length = m.specs.length;

      version (explain) {
        writefln("    assign specs");
      }

      buildTable(m, dims - 1, groups, ~none);

      version (explain) {
        writefln("  assign slots");
      }

      foreach (int dim, vp; m.vp) {
        version (explain) {
          writefln("    dim %s", dim);
        }

        int i = 0;

        foreach (group; groups[dim]) {
          version (explain) {
            writefln("      group %d (%s)",
                     i,
                     group.map!(c => c.name).join(", "));
          }
          foreach (c; group) {
            (cast(Word*) c.info.deallocator)[m.slots[dim]].i = i;
          }

          ++i;
        }
      }

      m.firstDim = groups[0];
    }

    gdv.length = methods.map!(m => m.dispatchTable.length + m.slots.length).sum;

    version (explain) {
      writefln("Initializing global dispatch table - %d words", gdv.length);
    }

    Word* mp = gdv.ptr;

    foreach (m; methods) {
      version (explain) {
        writefln("  %s:", *m);
        writefln("    %s: %d strides: %s", mp, m.strides.length, m.strides);
      }
      m.info.strides = mp;
      foreach (stride; m.strides) {
        mp++.i = stride;
      }
      version (explain) {
        writefln("    %s: %d functions", mp, m.dispatchTable.length);
      }
      m.info.dispatchTable = mp;
      foreach (p; m.dispatchTable) {
        version (explain) {
          writefln("      %s", p);
        }
        mp++.p = cast(void*) p;
      }
    }

    foreach (m; methods) {
      import std.stdio;
      auto slot = m.slots[0];
      foreach (group; m.firstDim) {
        foreach (c; group) {
          //writeln("*** ", *c);
          Word* index = (cast(Word*) c.info.deallocator) + slot;
          index.p = m.info.dispatchTable + index.i;
        }
        //        m.info.dispatchTable[i].p = m.info.dispatchTable[i].i
      }
      foreach (spec; m.specs) {
        auto nextSpec = findNext(spec, m.specs);
        *spec.info.nextPtr = nextSpec ? nextSpec.info.pf : null;
      }
    }
  }

  static auto findNext(Spec* spec, Spec*[] specs)
  {
    auto candidates =
      best(specs.filter!(other => isMoreSpecific(spec, other)).array);
    return candidates.length == 1 ? candidates.front : null;
  }

  void update()
  {
    seed();

    version (explain) {
      writefln("Scooping...");
    }

	foreach (mod; ModuleInfo) {
      foreach (c; mod.localClasses) {
        scoop(c);
      }
	}

    initClasses();
    layer();
    allocateSlots();
    calculateInheritanceRelationships();
    buildTables();
  }

  version (unittest) {
    int[] slots(alias MX)()
    {
      return methods.find!(m => m.info == &MX.ThisMethod.info)[0].slots;
    }

    Class* getClass(C)()
    {
      return classes.find!(c => c.info == C.classinfo)[0];
    }
  }
}

mixin template _implement(string M, alias S)
{
  import std.traits;
  static __gshared typeof(mixin(M)(MethodTag.init, Parameters!(S).init)).Specialization!(S) spec;
}

immutable bool hasVirtualParameters(alias F) = anySatisfy!(IsVirtual, Parameters!F);

unittest
{
  void meth(virtual!Object);
  static assert(hasVirtualParameters!meth);
  void nonmeth(Object);
  static assert(!hasVirtualParameters!nonmeth);
}

string _registerMethods(alias MODULE)()
{
  import std.array;
  string[] code;
  foreach (m; __traits(allMembers, MODULE)) {
    static if (is(typeof(__traits(getOverloads, MODULE, m)))) {
      foreach (o; __traits(getOverloads, MODULE, m)) {
        foreach (p; Parameters!o) {
          static if (IsVirtual!p) {
            auto meth =
              format(`Method!("%s", %s, %s)`,
                     m,
                     ReturnType!o.stringof,
                     Parameters!o.stringof[1..$-1]);
            code ~= format(`alias %s = %s.dispatcher;`, m, meth);
            code ~= format(`alias %s = %s.discriminator;`, m, meth);
            //code ~= format(`alias _%s = %s.discriminator;`, m, meth);
            break;
          }
        }
      }
    }
  }
  return join(code, "\n");
}

mixin template _registerSpecs(alias MODULE)
{
  static this() {
    foreach (m; __traits(allMembers, MODULE)) {
      static if (is(typeof(__traits(getOverloads, MODULE, m)))) {
        foreach (o; __traits(getOverloads, MODULE, m)) {
          static if (__traits(getAttributes, o).length) {
            foreach (a; __traits(getAttributes, o)) {
              static if (is(typeof(a) == method)) {
                mixin _implement!(mixin(`"` ~ a.id ~ `"`), o);
              } else {
                static if (is(a == method)) {
                  static assert(m[0] == '_',
                                m ~ ": method name must begin with an underscore, "
                                ~ "or be set in @method()");
                  mixin _implement!(m[1..$], o);
                }
              }
            }
          }
        }
      }
    }
  }
}

version (unittest) {

  mixin template _method(string name, R, A...)
  {
    alias ThisMethod = Method!(name, R, A);
    mixin("alias " ~ name ~ " = ThisMethod.discriminator;");
    mixin("alias " ~ name ~ " = ThisMethod.dispatcher;");
  }

  mixin template implement(alias M, alias S)
  {
    import std.traits;
    static __gshared typeof(M(MethodTag.init, Parameters!(S).init)).Specialization!(S) spec;
  }

  struct Restriction
  {
    Runtime.Registry saved;

    static auto save(M...)()
    {
      Runtime.Registry temp;
      bool[ClassInfo] keep;

      foreach (mi; M) {
        keep[mi.classinfo] = true;
      }

      foreach (mi; Runtime.methodInfos.values) {
        if (mi.vp.any!(vp => vp in keep)) {
          temp[mi] = mi;
        }
      }

      Restriction save = Restriction(Runtime.methodInfos);
      Runtime.methodInfos = temp;

      return save;
    }

    ~this()
    {
      Runtime.methodInfos = saved;
    }
  }

  private auto names(S)(S seq)
  {
    return seq.map!(c => c.name).join(",");
  }

  private auto sortedNames(S)(S seq)
  {
    string[] names = seq.map!(c => c.name).array;
    sort(names);
    return names.join(",");
  }

  mixin template Restrict(M...)
  {
    auto guard = Restriction.save!(M)();
  }
}

unittest
{
  // A*  C*
  //  \ / \
  //   B*  D
  //   |   |
  //   X   Y

  // A*   C*
  // |   / \
  // B* /   D
  // | /    |
  // X      Y

  interface A { }
  interface C { }
  interface D : C { }
  interface B : A, C { }
  class X : B { }
  class Y : D { }

  mixin _method!("a", void, virtual!A) aA;
  mixin _method!("c", void, virtual!C) cC;
  mixin _method!("b", void, virtual!B) bB;

  Runtime rt;
  mixin Restrict!(A, B, C, D, X, Y);

  rt.seed();
  assert(rt.classMap.length == 3);
  assert(A.classinfo in rt.classMap);
  assert(B.classinfo in rt.classMap);
  assert(C.classinfo in rt.classMap);

  version (explain) {
    writefln("Scooping X...");
  }

  rt.scoop(X.classinfo);
  assert(rt.classMap.length == 4);
  assert(X.classinfo in rt.classMap);

  version (explain) {
    writefln("Scooping Y...");
  }

  rt.scoop(Y.classinfo);
  assert(Y.classinfo in rt.classMap);
  assert(D.classinfo in rt.classMap);
  assert(rt.classMap.length == 6);

  int target = 2;
  int[] a = [ 1, 2, 3 ];
  assert(a.any!(x => x == target));

  rt.initClasses();
  assert(rt.classMap[A.classinfo].directBases.empty);
  assert(rt.classMap[C.classinfo].directBases.empty);
  assert(rt.classMap[B.classinfo].directBases.names == "A,C");
  assert(rt.classMap[D.classinfo].directBases.names == "C");

  assert(A.classinfo.base is null);
  assert(Object.classinfo.base is null);
  assert(X.classinfo.base !is null);
  assert(!rt.classMap[A.classinfo].isClass);
  assert(rt.classMap[X.classinfo].isClass);

  rt.layer();
  assert(rt.classes.names == "A,C,B,D,X,Y");

  rt.allocateSlots();

  assert(rt.slots!aA == [ 0 ]);
  assert(rt.slots!cC == [ 1 ]);
  assert(rt.slots!bB == [ 2 ]);

  rt.calculateInheritanceRelationships();
  assert(rt.getClass!(A).conforming.values.sortedNames == "A,B,X");
  assert(rt.getClass!(B).conforming.values.sortedNames == "B,X");
  assert(rt.getClass!(C).conforming.values.sortedNames == "B,C,D,X,Y");
  assert(rt.getClass!(D).conforming.values.sortedNames == "D,Y");
  assert(rt.getClass!(Y).conforming.values.sortedNames == "Y");

  rt.buildTables();
}

unittest
{
  // A*
  // |
  // B
  // |
  // C*
  // |
  // D

  interface A { }
  interface B : A { }
  interface C : B { }
  class D : C { }

  mixin _method!("a", void, virtual!A);
  mixin _method!("c", void, virtual!C);

  Runtime rt;
  mixin Restrict!(A, B, C);
  assert(rt.methodInfos.length == 2);

  rt.seed();
  assert(rt.classMap.length == 2);

  version (explain) {
    writefln("Scooping D...");
  }

  rt.scoop(D.classinfo);
  assert(A.classinfo in rt.classMap);
  assert(B.classinfo in rt.classMap);
  assert(C.classinfo in rt.classMap);
  assert(D.classinfo in rt.classMap);

  rt.initClasses();
  rt.layer();
  rt.allocateSlots();
}

unittest
{
  interface Matrix { }
  class DenseMatrix : Matrix { }
  class DiagonalMatrix : Matrix { }

  mixin _method!("plus", void, virtual!(immutable Matrix), virtual!(immutable Matrix));

  mixin implement!(plus, function void(immutable Matrix a, immutable Matrix b) { });
  mixin implement!(plus, function void(immutable Matrix a, immutable DiagonalMatrix b) { });
  mixin implement!(plus, function void(immutable DiagonalMatrix a, immutable Matrix b) { });
  mixin implement!(plus, function void(immutable DiagonalMatrix a, immutable DiagonalMatrix b) { });

  Runtime rt;
  mixin Restrict!(Matrix, DenseMatrix, DiagonalMatrix);

  rt.seed();

  version (explain) {
    writefln("Scooping...");
  }

  rt.scoop(DenseMatrix.classinfo);
  rt.scoop(DiagonalMatrix.classinfo);

  rt.initClasses();
  rt.layer();
  rt.allocateSlots();
  rt.calculateInheritanceRelationships();

  auto specs = rt.methods[0].specs;

  foreach (a; 0..3) {
    foreach (b; 0..3) {
      bool expected = a > b && !(a == 1 && b == 2 || a == 2 && b == 1);
      assert(Runtime.isMoreSpecific(specs[a], specs[b]) == expected,
             format("a = %d, b = %d: expected %s", a, b, expected));
    }
  }

  assert(Runtime.findNext(specs[0], specs) == null);
  assert(Runtime.findNext(specs[1], specs) == specs[0]);
  assert(Runtime.findNext(specs[2], specs) == specs[0]);
  assert(Runtime.findNext(specs[3], specs) == null);

  rt.buildTables();
}

unittest
{
  class Matrix { }
  class DenseMatrix : Matrix { }
  class DiagonalMatrix : Matrix { }

  mixin _method!("plus", void, virtual!Matrix, virtual!Matrix);
  // intentionally ambiguous
  mixin implement!(plus, function void(DiagonalMatrix a, Matrix b) { });
  mixin implement!(plus, function void(Matrix a, DiagonalMatrix b) { });

  Runtime rt;
  mixin Restrict!(Matrix, DenseMatrix, DiagonalMatrix);

  rt.seed();

  version (explain) {
    writefln("Scooping...");
  }

  rt.scoop(DenseMatrix.classinfo);
  rt.scoop(DiagonalMatrix.classinfo);

  rt.initClasses();
  rt.layer();
  rt.allocateSlots();
  rt.calculateInheritanceRelationships();

  rt.buildTables();
  string error;

  try {
    plus(new Matrix, new Matrix);
  } catch (UndefinedCallError e) {
    error = e.msg;
  }

  assert(error == "this call to 'plus' is not implemented");

  try {
    plus(new DiagonalMatrix, new DiagonalMatrix);
  } catch (AmbiguousCallError e) {
    error = e.msg;
  }

  assert(error == "this call to 'plus' is ambiguous");
}
