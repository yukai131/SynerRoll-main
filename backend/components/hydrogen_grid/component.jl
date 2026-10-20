struct HydrogenGrid <: AbstractComponent
    config::ComponentConfig
end

component_schema(::Type{HydrogenGrid}) = get_component_schema("HGRID")

component_result_bindings(::Type{HydrogenGrid}) = ResultBinding[]

function component_result_bindings(component::HydrogenGrid)
    c = component_code(component)
    return [
        ResultBinding("HGRID", Symbol("H_HGRID_in_", c), "power"),
        ResultBinding("HGRID", Symbol("H_HGRID_out_", c), "power"),
    ]
end

function HydrogenGrid(comp_dict::Dict{String, Any})
    config = create_component_config(
        comp_dict,
        component_schema(HydrogenGrid);
        component_name="HydrogenGrid",
        special_validator=normalized_dict -> validate_special_rules(HydrogenGrid, normalized_dict),
    )
    return HydrogenGrid(config)
end
