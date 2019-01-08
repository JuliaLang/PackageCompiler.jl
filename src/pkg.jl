using Pkg
using Pkg.TOML

const manifest_memoize = Ref{Dict{String, Any}}()

function current_manifest()
    if !isassigned(manifest_memoize)
        manifest_memoize[] = TOML.parsefile(replace(Base.active_project(), "Project.toml" => "Manifest.toml"))
    end
    return manifest_memoize[]
end

"""
Looks up the UUID of a package from the current manifest file
"""
function package_uuid(name::AbstractString, manifest::Dict = current_manifest())
    haskey(manifest, name) || error("Package $name not found in current manifest")
    pkg = manifest[name]
    isempty(pkg) && error("Package $name exist in manifest, but array is empty - faulty manifest?")
    length(pkg) > 1 && @warn "There are multiple packages for $name installed. Choosing first!"
    Base.UUID(first(pkg)["uuid"])
end
function in_manifest(name::AbstractString, manifest::Dict = current_manifest())
    haskey(manifest, name) || return false
end

function require_uninstalled(name::AbstractString, mod = Main)
    pkg = Base.PkgId(package_uuid(name), name)
    psym = Symbol(name)
    @eval mod begin
        if !isdefined($mod, $(QuoteNode(psym)))
            const $psym = Base.require($pkg)
        end
    end
end


function extract_used_packages(file::String)
  namespaces = unique(
    getindex.(
      eachmatch(r"([\u00A0-\uFFFF\w_!´]*@?[\u00A0-\uFFFF\w_!´]+)\.",
      read(file, String)
    ), 1)
  )
  # only use names that are also in current manifest
  return filter(in_manifest, namespaces)
end


"""
Extracts using statements from a julia file.
"""
function extract_using(path, usings = Set{String}())
    src = read(path, String)
    regex = r"using ([\u00A0-\uFFFF\w_!´]+)(,[ \u00A0-\uFFFF\w_!´]+)?"
    for match in eachmatch(regex, src)
        push!(usings, match[1])
        if match[2] !== nothing
            pkgs = filter!((!)∘isempty, replace.(split(match[2], ','), (" " => "",)))
            union!(usings, pkgs)
        end
    end
    return usings
end
