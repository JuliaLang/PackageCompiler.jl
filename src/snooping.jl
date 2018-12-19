using Pkg, Serialization

function get_dependencies(package_root)
    project = joinpath(package_root, "Project.toml")
    if !isfile(project)
        error("Your package needs to have a Project.toml for static compilation. Please read here how to upgrade:")
    end
    project_deps = Pkg.TOML.parsefile(project)["deps"]
    Symbol.(keys(project_deps))
end

"""
Recursively get's all dependencies for `package` and makes sure they're installed!
Note, that this will mutate your current Pkg environment!
Returns all dependencies!
"""
function recursive_install_dependencies(package::Symbol, deps = Set{Symbol}(), visited = Set{Symbol}(); installed = Pkg.installed())
  package in visited && return deps
  if !haskey(installed, string(package))
    @info "installing $package"
    Pkg.add(string(package))
  end
  push!(visited, package)
  M = @eval Module() ((import $package; $package))
  project = joinpath(dirname(pathof(M)), "..", "Project.toml")
  require = joinpath(dirname(pathof(M)), "..", "REQUIRE")
  if isfile(project)
    toml = Pkg.TOML.parsefile(project)
    if haskey(toml, "deps")
      push!(deps, Symbol.(keys(toml["deps"]))...)
    end
  elseif isfile(require)
    for line in eachline(require)
      isempty(line) && continue
      any(x-> occursin(x, line), (
        "windows", "osx", "unix", "linux", "julia", "#"
      )) && continue
      m = match(r"([a-zA-Z\-]+)", line)
      if m == nothing
        @warn("Can't match package: $line") # just means we got our regex wrong
      else
        push!(deps, Symbol(m[1]))
      end
    end
  else
    error("No Project.toml or REQUIRE found for package $package")
  end
  foreach(x-> get_dependencies(x, deps, visited; installed = installed), copy(deps))
  deps
end


function snoop(package, snoopfile, outputfile; additional_packages = Symbol[])
    command = """
    using Pkg, $package
    using $(join(additional_packages, ", "))
    package_path = abspath(joinpath(dirname(pathof($package)), ".."))
    Pkg.activate(package_path)
    Pkg.instantiate()
    include($(repr(snoopfile)))
    """
    tmp_file = joinpath(@__DIR__, "precompile_tmp.jl")
    julia_cmd = build_julia_cmd(
        get_backup!(false, nothing), nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, "all", nothing, "0", nothing, nothing, nothing, nothing
    )
    run(`$julia_cmd --trace-compile=$tmp_file -e $command`)
    M = Module()
    @eval M begin
        using Pkg
        using $package
        package_path = abspath(joinpath(dirname(pathof($package)), ".."))
        Pkg.activate(package_path)
        Pkg.instantiate()
    end
    deps = [get_dependencies(M.package_path); collect(additional_packages)]
    deps_usings = string("using ", join(deps, ", "))
    @eval M begin
        $(Meta.parse(deps_usings))
    end
    open(outputfile, "w") do io
        println(io, """
        # Initialize Pkg
        Base.init_load_path()
        Base.init_depot_path()
        using Pkg
        Pkg.activate($(repr(M.package_path)))
        # Initialize REPL module for Docs
        using REPL
        Base.REPL_MODULE_REF[] = REPL
        using $package
        $deps_usings
        """)
        for line in eachline(tmp_file)
            # replace function instances, which turn up as typeof(func)().
            # TODO why would they be represented in a way that doesn't actually work?
            line = replace(line, r"typeof\(([\u00A0-\uFFFF\w_!´\.]*@?[\u00A0-\uFFFF\w_!´]+)\)\(\)" => s"\1")
            expr = Meta.parse(line, raise = false)
            if expr.head != :error
                # we need to wrap into try catch, since some anonymous symbols won't
                # be found... there is also still a high probability, that some modules
                # aren't defined
                println(io, "try;", line, "; catch e; @warn \"could not eval $line\" exception = e; end")
            end
        end
    end
    rm(tmp_file, force = true)
    outputfile
end


"""
    snoop_userimg(userimg, packages::Tuple{String, String}...)

    Traces all function calls in packages and writes out `precompile` statements into the file `userimg`
"""
function snoop_userimg(userimg, packages::Tuple{String, String}...; additional_packages = Symbol[])
    snooped_precompiles = map(packages) do package_snoopfile
        package, snoopfile = package_snoopfile
        module_file = ""
        abs_package_path = if ispath(package)
            path = normpath(abspath(package))
            module_file = joinpath(path, "src", basename(path) * ".jl")
            path
        else
            module_file = Base.find_package(package)
            normpath(module_file, "..", "..")
        end
        module_name = Symbol(splitext(basename(module_file))[1])
        file2snoop = normpath(abspath(joinpath(abs_package_path, snoopfile)))
        package = package_folder(get_root_dir(abs_package_path))
        isdir(package) || mkpath(package)
        precompile_file = joinpath(package, "precompile.jl")
        snoop(module_name, file2snoop, precompile_file; additional_packages = additional_packages)
        return precompile_file
    end
    # merge all of the temporary files into a single output
    open(userimg, "w") do output
        println(output, """
        # Prevent this from being put into the Main namespace
        Core.eval(Module(), quote
        """)
        for (pkg, _) in packages
            println(output, "import $pkg")
        end
        for path in snooped_precompiles
            open(input -> write(output, input), path)
            println(output)
        end
        println(output, "end) # eval")
    end
    nothing
end
