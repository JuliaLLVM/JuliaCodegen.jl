# Exceptions, scopes and the statements that throw, through the JIT.

using Base.ScopedValues

@noinline e_throws(x) = x > 0 ? x : error("negative: $x")
e_catch(x) = try e_throws(x) catch; -1 end
e_catch_value(x) = try e_throws(x) catch err; err end
e_catch_type(x) = try e_throws(x) catch err; err isa ErrorException end
e_finally(x, log) = try e_throws(x) finally push!(log, x) end
e_rethrow(x) = try e_throws(x) catch; rethrow() end
e_nested(x) = try
    try e_throws(x) catch; e_throws(x + 10) end
catch err
    sprint(showerror, err)
end
function e_phic(n)
    i = 0
    s = 0
    try
        for j in 1:n
            i = j
            s += e_throws(5 - j)
        end
    catch
        return (i, s)
    end
    return (0, s)
end
e_bounds(v, i) = try v[i] catch err; err isa BoundsError end
e_current() = try error("x") catch; current_exceptions()[end].exception end
const E_SCOPED = ScopedValue(1)
e_scoped(x) = (with(E_SCOPED => x) do; E_SCOPED[] end, E_SCOPED[])
function e_undef(c)
    local y
    c && (y = 1)
    return y
end
e_global_counter = 0
e_assign(x) = (global e_global_counter = x; e_global_counter)
global e_typed_global::Int = 1
e_typed_read() = e_typed_global + 1
e_typed_assign(x) = (global e_typed_global = x; e_typed_global)
e_read_undefined() = e_never_assigned
global e_never_assigned
e_read_imported() = Base.Filesystem.JL_O_RDONLY + 0   # (an imported constant)

@testset "exceptions" begin

@testset "try" begin
    for x in (1, -1)
        @cgtest e_catch(x)
        @cgtest e_catch_value(x)
        @cgtest e_catch_type(x)
        @cgtest e_rethrow(x)
        @cgtest e_nested(x)
        @cgtest e_finally(x, Int[])
    end
    for n in (2, 6, 8)
        @cgtest e_phic(n)
    end
    @cgtest e_bounds([1, 2], 3)
    @cgtest e_bounds([1, 2], 2)
    @cgtest e_current()
end

@testset "scopes" begin
    @cgtest e_scoped(5)
end

@testset "statements" begin
    @cgtest e_undef(true)
    @cgtest e_undef(false)       # UndefVarError
    @test cgrun(e_assign, 7) == 7
    @test e_global_counter == 7
    # globals with a declared type, and declared globals without a value
    @cgtest e_typed_read()
    @test cgrun(e_typed_assign, 5) == 5
    @test e_typed_global == 5
    @cgtest e_read_undefined()
end

@testset "globals" begin
    # read and written through the binding, as native code does
    @test @filecheck begin
        @check_label "define"
        @check_not "@ijl_apply_generic"
        @check "store atomic ptr addrspace(10) %{{[0-9]+}}, ptr %{{[0-9]+}} release"
        @check "load atomic ptr addrspace(10), ptr %{{[0-9]+}} unordered"
        @check "call void @ijl_undefined_var_error"
        test_ir(e_assign, (Int,))
    end
    # a typed global is assigned through the runtime, which converts the value
    @test occursin("@ijl_apply_generic", test_ir(e_typed_assign, (Int,)))
end

@testset "code" begin
    # the handler as the dialect's code generator installs it
    ir = test_ir(e_catch, (Int,))
    if JuliaCodegen.CodegenConfig().dialect.except_enter === :task_buffer
        @test @filecheck begin
            @check "call { i32, ptr } @julia.except_enter("
            print(ir)
        end
    else
        rt = JuliaCodegen.runtime_facts()
        @test @filecheck begin
            @check "alloca [$(rt.handler_size) x i8], align $(rt.handler_align)"
            @check "call void @ijl_enter_handler("
            @check "call i32 @$(rt.setjmp)("
            print(ir)
        end
    end
end

end
