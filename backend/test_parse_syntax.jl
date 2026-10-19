
for f in ["utils/server_utils.jl", "server.jl"]
    try
        Meta.parseall(read(f, String))
        println("PARSE_OK ", f)
    catch e
        println("PARSE_FAIL ", f, " ", sprint(showerror, e))
    end
end
