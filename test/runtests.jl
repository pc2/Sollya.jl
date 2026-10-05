using Test
using Sollya
using Serialization
import Distributed

# Retain each test's native objects until its finally block, including failures.
function with_objects(f)
    owned = SollyaObject[]
    keep(obj) = (push!(owned, obj); obj)
    try
        return f(keep)
    finally
        foreach(close, reverse(owned))
    end
end

@testset "Sollya.jl" begin
    @test isfile(library_path())
    @test isempty(Test.detect_ambiguities(Sollya; recursive=true))
    include("objects.jl")
    include("functions.jl")
    include("upstream/cases.jl")
    include("concurrency.jl")
    drain_finalizers!()
end
