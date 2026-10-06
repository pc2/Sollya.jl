using Test
using Sollya
using Serialization
import Distributed

@testset "Sollya.jl" begin
    @test isfile(library_path())
    @test isempty(Test.detect_ambiguities(Sollya; recursive = true))
    include("objects.jl")
    include("functions.jl")
    include("upstream/cases.jl")
    include("concurrency.jl")
    drain_finalizers!()
end
