# hydrogen_grid/flexibility.jl — 氢网电功率灵活性接口
# ────────────────────────────────────────────────────────────
# 氢网不直接与电母线交换有功功率，其耦合影响由系统全约束优化计算。
# 首版氢网不作为电侧 POI 参与灵活性截断，电灵活性恒为零。
# ────────────────────────────────────────────────────────────

function calculate_component_flexibility_impl(
    component::HydrogenGrid,
    context::ComponentFlexibilityContext,
)
    return zero_component_flexibility_results(
        component,
        context,
        "not_direct_electric_resource",
    )
end
