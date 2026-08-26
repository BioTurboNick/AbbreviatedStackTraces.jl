#= Which frames count as user code comes down to classifying the file a frame names. This is
where each Julia release has moved the ground: 1.14 dropped the `./` prefix Base used on its
own files, which silently turned every Base frame into user code and stopped the package
hiding anything at all. =#

const AST = AbbreviatedStackTraces

@testset "path classification" begin
    #= A live sample, so this tracks whatever shape the running Julia actually uses rather
    than a shape that was current when the test was written. =#
    base_file = let
        stack = try
            sum([])
        catch
            stacktrace(catch_backtrace())
        end
        String(first(stack).file)
    end
    @test AST.is_julia(base_file)
    @test !occursin(r"[/\\]", base_file) || startswith(base_file, r".[/\\]")

    @testset "Base names its files relative to Julia's source tree" begin
        @test AST.is_julia("reducedim.jl")   # 1.14 and later
        @test AST.is_julia("./reducedim.jl") # earlier
        @test AST.is_julia(".\\reducedim.jl")
        @test AST.is_julia("boot.jl")        # Core
    end

    @testset "stdlibs and installed packages are internal" begin
        @test AST.is_julia("/opt/julia/share/julia/stdlib/v1.14/Dates/src/io.jl")
        @test AST.is_julia("C:\\workdir\\usr\\share\\julia\\stdlib\\v1.14\\Dates\\src\\io.jl")
        @test AST.is_julia("/home/u/.julia/packages/BenchmarkTools/2di2E/src/execution.jl")
        @test AST.is_julia("D:\\.julia\\packages\\BenchmarkTools\\2di2E\\src\\execution.jl")
    end

    @testset "user code is not internal" begin
        # A package being developed is the user's own code
        @test !AST.is_julia("/home/u/.julia/dev/MyPkg/src/MyPkg.jl")
        @test !AST.is_julia("D:\\.julia\\dev\\MyPkg\\src\\MyPkg.jl")
        # Anything a user writes reaches a trace as an absolute path, even via a relative include
        @test !AST.is_julia("/home/u/scripts/run.jl")
        @test !AST.is_julia("D:\\source\\scripts\\run.jl")
        #= The REPL's pseudo-files have no directory, like a Base file from 1.14 on, but they
        carry no extension either. `none` is what `julia -e` reports. =#
        @test !AST.is_julia("REPL[1]")
        @test !AST.is_julia("./REPL[1]")
        @test !AST.is_julia("none")
        @test AST.is_repl("REPL[1]")
        @test AST.is_repl("./REPL[1]")
    end

    @testset "broadcast.jl drives the materialize special case" begin
        @test AST.is_broadcast("broadcast.jl")   # 1.14 and later
        @test AST.is_broadcast("./broadcast.jl") # earlier
        @test AST.is_broadcast(".\\broadcast.jl")
        # Only Base's own; a package that happens to have one is still internal, not broadcast
        @test !AST.is_broadcast("/home/u/.julia/packages/Foo/abc/src/broadcast.jl")
        @test !AST.is_broadcast("reducedim.jl")
        @test !AST.is_broadcast("mybroadcast.jl")
    end
end
