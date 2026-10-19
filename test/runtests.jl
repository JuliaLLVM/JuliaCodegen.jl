using Test
using JuliaCodegen

@testset "JuliaCodegen" begin

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(JuliaCodegen)
end

end
