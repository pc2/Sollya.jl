# Optional direct reuse of a local Sollya source distribution's C tests.
# No source or dependency downloads, and all build products stay in a temp dir.
using Sollya
using Libdl
using Test

source = isempty(ARGS) ? get(ENV, "SOLLYA_TEST_SOURCE", "") : only(ARGS)
isempty(source) && error("Pass the local Sollya 8.0 source directory as the only argument")
source = abspath(source)
isdir(joinpath(source, "tests-lib")) || error("No tests-lib directory in $source")
compiler = Sys.which(get(ENV, "CC", "cc"))
compiler === nothing && error("A C compiler is required; set CC to its executable path")

native = library_path()
prefix = dirname(dirname(native))
libdirs = [joinpath(prefix, "lib"), "/opt/homebrew/lib", "/usr/local/lib"]
mpfr = Libdl.find_library(["libmpfr"], libdirs)
gmp = Libdl.find_library(["libgmp"], libdirs)
isempty(mpfr) && error("Cannot find MPFR for native C tests")
isempty(gmp) && error("Cannot find GMP for native C tests")
function linkpath(name)
    handle = Libdl.dlopen(name)
    try
        return Libdl.dlpath(handle)
    finally
        Libdl.dlclose(handle)
    end
end
mpfr, gmp = linkpath(mpfr), linkpath(gmp)
includes = filter(
    isdir,
    [
        get(ENV, "SOLLYA_INCLUDE_DIR", joinpath(prefix, "include")),
        "/opt/homebrew/include",
        "/usr/local/include",
    ],
)
flags = ["-I$directory" for directory in includes]
normalize(text) = replace(strip(text), r"\s+" => " ", "_x_" => "x")

mktempdir() do build
    @testset "Original Sollya 8.0 C regressions" begin
        for name in (
            "tcoeff",
            "tfpminimax",
            "tget_constant_as_uint64_array",
            "tget_element_in_list",
        )
            @testset "$name" begin
                input = joinpath(source, "tests-lib", "$name.c")
                reference = joinpath(source, "tests-lib", "$name.reference")
                executable = joinpath(build, name)
                run(Cmd([compiler, flags..., input, native, mpfr, gmp, "-o", executable]))
                actual = read(Cmd([executable]), String)
                @test normalize(actual) == normalize(read(reference, String))
            end
        end
    end
end
