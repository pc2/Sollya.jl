using Sollya

request = ApproximationRequest("erf(x)", (0, 1//4);
                               basis=5, formats=:single, precision=256)
result = approximate(request)
println("Exact coefficients (ascending): ", result.coefficients)
println("Certified absolute approximation error: ", result.norm_bound)

# Parallel coefficient generation with independent native state per process.
requests = [ApproximationRequest("erf(x)", (0,1//4); precision=bits)
            for bits in (128,256,384)]
SollyaPool(2) do pool
    for result in approximate_many(pool, requests)
        println("precision=", result.precision, ": upper bound=", result.norm_bound[2])
    end
end
