using Pkg
using Pkg.Artifacts

destination = abspath(only(ARGS))
mkpath(destination)
notices = String["PSFA bundled third-party notices", "COPT native libraries and licenses are not distributed."]
for (uuid, dependency) in sort!(collect(Pkg.dependencies()); by=p -> something(p.second.name, ""))
    dependency.source === nothing && continue
    Pkg.Types.is_stdlib(uuid) && continue
    source = dependency.source
    target = joinpath(destination, "packages", dependency.name, basename(source))
    mkpath(dirname(target))
    cp(source, target; force=true)
    # Native COPT is resolved from the user's installation at runtime.
    if dependency.name == "COPT"
        mkpath(joinpath(target, "deps"))
        write(joinpath(target, "deps", "deps.jl"), "const libcopt = ENV[\"SYNERROLL_COPT_LIBRARY\"]\n")
    end
    for name in readdir(source)
        if occursin(r"(?i)^(licen[cs]e|copying|notice)", name) && isfile(joinpath(source, name))
            push!(notices, "\n===== $(dependency.name) $(something(dependency.version, "")) / $name =====\n" * read(joinpath(source, name), String))
        end
    end
    artifact_file = joinpath(source, "Artifacts.toml")
    isfile(artifact_file) || continue
    dependency.name == "COPT" && continue
    artifacts = select_downloadable_artifacts(artifact_file; include_lazy=true)
    for (name, metadata) in artifacts
        ensure_artifact_installed(name, artifact_file)
        hash = Base.SHA1(metadata["git-tree-sha1"])
        artifact_source = artifact_path(hash)
        artifact_target = joinpath(destination, "artifacts", string(hash))
        if !isdir(artifact_target)
            mkpath(dirname(artifact_target))
            cp(artifact_source, artifact_target)
            for (root, _, files) in walkdir(artifact_source)
                for filename in files
                    if occursin(r"(?i)^(licen[cs]e|copying|notice)", filename)
                        file = joinpath(root, filename)
                        filesize(file) < 1_000_000 || continue
                        push!(notices, "\n===== $(dependency.name) artifact $name / $(relpath(file, artifact_source)) =====\n" * read(file, String))
                    end
                end
            end
        end
    end
end
write(joinpath(dirname(dirname(destination)), "THIRD-PARTY-NOTICES.txt"), join(notices, "\n"))
println("Exported offline Julia depot to $destination")
