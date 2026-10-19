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
