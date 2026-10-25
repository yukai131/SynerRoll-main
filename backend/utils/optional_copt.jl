using Libdl

function local_copt_library()
    get(ENV, "SYNERROLL_DISABLE_COPT", "0") == "1" && return nothing
    homes = split(get(ENV, "COPT_HOME", ""), Sys.iswindows() ? ';' : ':')
    if Sys.iswindows()
        for root in unique([get(ENV, "ProgramFiles", "C:\\Program Files"), "C:\\"])
            isdir(root) || continue
            append!(homes, [joinpath(root, name) for name in readdir(root) if startswith(lowercase(name), "copt")])
        end
    end
    for home in homes
        isempty(home) && continue
        library = joinpath(home, Sys.iswindows() ? "bin" : "lib", Sys.iswindows() ? "copt.dll" : "libcopt.$(Libdl.dlext)")
        isfile(library) && return abspath(library)
    end
    return nothing
end

const COPT_LIBRARY = local_copt_library()
const COPT_LOAD_ERROR = Ref("")
const COPT_AVAILABLE = if COPT_LIBRARY === nothing
    COPT_LOAD_ERROR[] = "请自行安装 COPT，并设置 COPT_HOME 指向安装目录，然后重启 PSFA。"
    false
else
    ENV["SYNERROLL_COPT_LIBRARY"] = COPT_LIBRARY
    try
        @eval import COPT
        true
    catch error
        COPT_LOAD_ERROR[] = sprint(showerror, error)
        @warn "COPT 未能加载；HiGHS 仍可使用" exception=error
        false
    end
end

function require_copt()
    COPT_AVAILABLE || error("COPT 不可用：$(COPT_LOAD_ERROR[])")
    return nothing
end
