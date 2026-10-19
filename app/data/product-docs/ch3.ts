import type { DocChapter } from './types'

export const chapter3: DocChapter = {
  id: 'ch3',
  title: '第三章 · 灵活性评价',
  summary: '概念、数学定义、完整计算实例、设备口径、界面操作与指标解读',
  sections: [
    {
      id: 'ch3-concept',
      title: '3.1 概念与使用场景',
      blocks: [
        {
          type: 'p',
          text: '灵活性量化评估回答的问题是：在给定基准运行状态下、一个模型时段 Δt 内，系统（以及各设备）还能向上/向下调节多少有功功率，相对于下一时刻的调节需求是否够用。'
        },
        {
          type: 'list',
          items: [
            '「上调」= 增加系统净注入（发电增出力、储能多放/少充、柔性负荷减用电、并网点多上送/少购入）。',
            '「下调」= 减少系统净注入（发电降出力、储能多充/少放、柔性负荷增用电、并网点少上送/多购入）。',
            '评价时间尺度 = 模型时段长度 Δt（如 1h、15m、5m），不另设独立响应时间参数。'
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '四层计算链'
        },
        {
          type: 'formula',
          text: '单设备灵活性  →  系统灵活性供给  →  系统灵活性需求  →  灵活性裕度 / 缺额 / 充足率',
          caption: '灵活性评价的固定流水线'
        },
        {
          type: 'h',
          level: 3,
          text: '定位与意义'
        },
        {
          type: 'list',
          items: [
            '后验评价，不改调度：在基准调度求解之后执行，不回写基准结果。',
            '识别瓶颈：哪一时刻不够调、缺多少、是内部设备不够还是 POI 并网口卡住、哪类设备在承担调节。',
            '决策支撑：储能配置、柔性负荷容量、并网点（POI）容量与上送/购入比例、AGC 跟踪能力评估。',
            '与仿真计算的关系：仿真每次基准求解落库后自动触发灵活性评价，结果写入任务库并推送前端。'
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '适用场景'
        },
        {
          type: 'table',
          headers: ['使用目的', '默认需求来源', '说明'],
          rows: [
            ['计划 / AGC 跟踪', 'AGC 或计划功率', '评价 POI 跟踪目标所需附加调节量'],
            ['平抑新能源波动', '净负荷变化', '风光 + 负荷变化形成的双向调节需求'],
            ['经济运行、新能源消纳', '净负荷变化或用户给定', '先得基准调度，再选一种需求口径'],
            ['灵活性增强', '用户给定目标或净负荷变化', '检验最低裕度目标、指导再调度'],
            ['离网边界（无 GRID）', '净负荷变化或用户给定', '无 POI 截断、禁用 AGC 目标']
          ]
        },
        {
          type: 'callout',
          tone: 'warning',
          title: '需求来源三选一',
          text: 'requirement_source 必须显式选择：净负荷变化（net_load_change）/ AGC 计划（agc_or_schedule）/ 用户自定义（user_defined），不自动叠加。新建计算任务默认启用灵活性评价，并固定采用项目配置中的最底层时层。'
        },
        {
          type: 'h',
          level: 3,
          text: '首版边界'
        },
        {
          type: 'list',
          items: [
            '单母线、单 POI；不考虑内部线路潮流、线路容量、网络阻塞。',
            '系统供给 = min(内部设备灵活性合计, POI 剩余交换空间)；离网时供给 = 内部合计。',
            '设备实际贡献按可用灵活性比例分摊（统计口径，不是经济调度指令）。',
            '不做失负荷/弃电联合优化，不做全约束双向极值重优化，不做可执行再调度。',
            '评价层结果读取要求精确时间戳，避免用旧调度点冒充当前基准。'
          ]
        }
      ]
    },
    {
      id: 'ch3-math',
      title: '3.2 数学定义',
      blocks: [
        {
          type: 'h',
          level: 3,
          text: '符号约定'
        },
        {
          type: 'list',
          items: [
            '发电与储能放电为正，储能充电为负；负荷用电为正。',
            'P_POI > 0 向电网上送，P_POI < 0 从电网购入。',
            'P^av 表示最大可用功率（风光），P 表示实际基准出力。',
            '界面与接口以 kW / kWh 为准；示例中为便于阅读使用 MW。'
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '并网点（POI）边界'
        },
        {
          type: 'formula',
          text: 'P_POI^max = α_sell × P_grid^cap\nP_POI^min = −α_buy × P_grid^cap',
          caption: '由 GRID 组件额定容量与上送/购入比例决定'
        },
        {
          type: 'formula',
          text: 'F_POI,t^up   = max(0,  P_POI^max − P_POI,t⁰)\nF_POI,t^down = max(0,  P_POI,t⁰ − P_POI^min)',
          caption: 'POI 剩余交换空间（系统边界，不是内部设备）'
        },
        {
          type: 'h',
          level: 3,
          text: '系统供给层'
        },
        {
          type: 'formula',
          text: 'F_int,t^up   = Σ_i F_i,t^up          （内部设备合计，不含 GRID）\nF_int,t^down = Σ_i F_i,t^down\nF_sup,t^up   = min(F_int,t^up,   F_POI,t^up)      （并网）\nF_sup,t^down = min(F_int,t^down, F_POI,t^down)',
          caption: '并网截断；离网时 F_sup = F_int'
        },
        {
          type: 'p',
          text: '瓶颈标记 binding_constraint：若内部合计 ≤ POI 空间，则为 internal_devices（设备不够）；否则上调记 poi_upper_limit、下调记 poi_lower_limit（并网口不够）。'
        },
        {
          type: 'formula',
          text: 'C_i,t^d = F_i,t^d × ( F_sup,t^d / F_int,t^d )     当 F_int > 0\nΣ_i C_i,t^d = F_sup,t^d,   0 ≤ C_i,t^d ≤ F_i,t^d',
          caption: 'POI 截断时设备贡献按比例分摊（仅统计归属）'
        },
        {
          type: 'h',
          level: 3,
          text: '系统需求层（三选一）'
        },
        {
          type: 'formula',
          text: '① 净负荷变化：\nN_t = L_rigid,t + Σ L_j,t − P_W,t^av − P_PV,t^av\nR_req,t^up   = max(0, N_{t+1} − N_t)\nR_req,t^down = max(0, N_t − N_{t+1})',
          caption: '净负荷用风光可用功率（不是限发后出力）'
        },
        {
          type: 'formula',
          text: '② AGC / 计划功率（目标是并网点功率，不是机组出力和）：\nR_AGC,t^up   = max(0, P_tar,t+1 − P_POI,t+1⁰)\nR_AGC,t^down = max(0, P_POI,t+1⁰ − P_tar,t+1)\n\n③ 用户自定义：直接给定非负上/下调需求。',
          caption: 'AGC 与用户自定义需求'
        },
        {
          type: 'h',
          level: 3,
          text: '裕度、缺额、充足率'
        },
        {
          type: 'formula',
          text: 'M_t^up   = F_sup,t^up   − R_req,t^up\nM_t^down = F_sup,t^down − R_req,t^down\nD_t = max(0, −M_t)\nA_t = F_sup,t / R_req,t          （需求为 0 时记「不适用」）',
          caption: '裕度 > 0 富余；< 0 缺额；充足率 ≥ 1 满足'
        },
        {
          type: 'table',
          headers: ['全时域指标', '公式', '单位'],
          rows: [
            ['最小裕度 M_min', 'min_t M_t，并记发生时刻', 'kW'],
            ['最大缺额 D_max', 'max_t D_t = max(0, −M_min)', 'kW'],
            ['缺额电量 E_def', 'Σ_t D_t × Δt', 'kWh'],
            ['单方向达标比例', '裕度≥0 的时段数 / 总时段数', '—'],
            ['双向达标比例', '上下调同时达标的时段占比', '—']
          ]
        },
        {
          type: 'callout',
          tone: 'tip',
          title: '读汇总时注意',
          text: '不要对逐时段充足率取平均代替达标比例——零需求时段「不适用」、过大的充足率会掩盖缺额。最大缺额与最小裕度强制一致。'
        }
      ]
    },
    {
      id: 'ch3-example',
      title: '3.3 计算实例（五时点）',
      blocks: [
        {
          type: 'p',
          text: '下面用一个含风电、光伏、火电、储能与刚性负荷的系统，完整走通灵活性评价。Δt = 1h，5 个时点 → 4 个评价区间。数值单位为 MW（界面为 kW）。'
        },
        {
          type: 'h',
          level: 3,
          text: '步骤 0 · 并网参数'
        },
        {
          type: 'formula',
          text: 'P_grid^cap = 120 MW,  α_sell = 0.8,  α_buy = 0.5\n⇒ P_POI^max = 96 MW,  P_POI^min = −60 MW',
          caption: '正 P_POI 上送，负为购电'
        },
        {
          type: 'h',
          level: 3,
          text: '步骤 1 · 基准运行数据'
        },
        {
          type: 'table',
          headers: ['时间', 'L_rigid', 'P_W^av', 'P_W', 'P_PV^av', 'P_PV'],
          rows: [
            ['t0 = 0:00', '100', '40', '35', '20', '15'],
            ['t1 = 1:00', '110', '50', '45', '30', '25'],
            ['t2 = 2:00', '105', '30', '30', '40', '40'],
            ['t3 = 3:00', '120', '20', '15', '25', '20'],
            ['t4 = 4:00', '115', '35', '30', '15', '10']
          ],
          caption: '负荷与新能源；t0 风电主动限发空间 = 40 − 35 = 5 MW'
        },
        {
          type: 'table',
          headers: ['时间', 'P_CP', 'P_ES', 'SOC'],
          rows: [
            ['t0', '80', '10', '70 MWh'],
            ['t1', '100', '−5', '65'],
            ['t2', '110', '20', '60'],
            ['t3', '70', '15', '65'],
            ['t4', '90', '−10', '60']
          ],
          caption: '火电与储能基准（放电为正）。火电 40≤P≤120，爬坡 ±30；储能 −20≤P≤30，爬坡 ±40'
        },
        {
          type: 'h',
          level: 3,
          text: '步骤 2 · 设备级灵活性'
        },
        {
          type: 'p',
          text: '以火电 t1 为例：F^up = min(120−100, 30×1) = 20；F^down = min(100−40, 30) = 30。其余设备同理（详见 3.4 节公式）。'
        },
        {
          type: 'table',
          headers: ['t', 'F_CP^up', 'F_CP^down', 'F_W^up', 'F_W^down', 'F_PV^up', 'F_PV^down', 'F_ES^up', 'F_ES^down'],
          rows: [
            ['t0', '30', '30', '5', '35', '5', '15', '20', '30'],
            ['t1', '20', '30', '5', '45', '5', '25', '35', '15'],
            ['t2', '10', '30', '0', '30', '0', '40', '10', '40'],
            ['t3', '30', '30', '5', '15', '5', '20', '15', '35'],
            ['t4', '30', '30', '5', '30', '5', '10', '40', '10']
          ],
          caption: '设备级上下调灵活性（MW）'
        },
        {
          type: 'table',
          headers: ['t', 'F_int^up', 'F_int^down'],
          rows: [
            ['t0', '30+5+5+20 = 60', '30+35+15+30 = 110'],
            ['t1', '20+5+5+35 = 65', '30+45+25+15 = 115'],
            ['t2', '10+0+0+10 = 20', '30+30+40+40 = 140'],
            ['t3', '30+5+5+15 = 55', '30+15+20+35 = 100'],
            ['t4', '30+5+5+40 = 80', '30+30+10+10 = 80']
          ],
          caption: '内部设备合计（不含 GRID）'
        },
        {
          type: 'h',
          level: 3,
          text: '步骤 3 · 基准 POI 与并网截断'
        },
        {
          type: 'formula',
          text: 'P_POI,t⁰ = P_W + P_PV + P_CP + P_ES − L_rigid',
          caption: '基准并网点功率'
        },
        {
          type: 'table',
          headers: ['t', 'P_POI⁰', 'F_POI^up', 'F_POI^down', 'F_sup^up', '上调瓶颈', 'F_sup^down', '下调瓶颈'],
          rows: [
            ['t0', '40', '56', '100', '56', 'POI 上限', '100', 'POI 空间'],
            ['t1', '55', '41', '115', '41', 'POI 上限', '115', '相等'],
            ['t2', '95', '1', '155', '1', 'POI 上限', '140', '内部设备'],
            ['t3', '0', '96', '60', '55', '内部设备', '60', 'POI 下限'],
            ['t4', '5', '91', '65', '80', '内部设备', '65', 'POI 空间']
          ],
          caption: '系统供给 = min(内部合计, POI 空间)。t2 距上送上限仅剩 1 MW！'
        },
        {
          type: 'p',
          text: '贡献分摊示例（t0 上调）：比例 ρ = 56/60 ≈ 0.933，则 C_CP=28、C_W=4.67、C_PV=4.67、C_ES=18.67，合计 56 MW。'
        },
        {
          type: 'h',
          level: 3,
          text: '步骤 4 · 需求（两种模式对比）'
        },
        {
          type: 'table',
          headers: ['区间', '净负荷 ΔN', 'R_req^up', 'R_req^down'],
          rows: [
            ['t0→t1', '−10', '0', '10'],
            ['t1→t2', '+5', '5', '0'],
            ['t2→t3', '+40', '40', '0'],
            ['t3→t4', '−10', '0', '10']
          ],
          caption: '净负荷模式：N_t = L − P_W^av − P_PV^av = [40, 30, 35, 75, 65]'
        },
        {
          type: 'table',
          headers: ['区间', 'P_POI,t+1⁰', 'P_tar,t+1', 'R_AGC^up', 'R_AGC^down'],
          rows: [
            ['t0→t1', '55', '70', '15', '0'],
            ['t1→t2', '95', '80', '0', '15'],
            ['t2→t3', '0', '20', '20', '0'],
            ['t3→t4', '5', '50', '45', '0']
          ],
          caption: 'AGC 模式：目标 POI 功率 P_tar = [40, 70, 80, 20, 50]'
        },
        {
          type: 'h',
          level: 3,
          text: '步骤 5 · 裕度与缺额'
        },
        {
          type: 'table',
          headers: ['区间', 'F_sup^up', 'R^up', 'M^up', 'F_sup^down', 'R^down', 'M^down'],
          rows: [
            ['t0→t1', '56', '0', '56', '100', '10', '90'],
            ['t1→t2', '41', '5', '36', '115', '0', '115'],
            ['t2→t3', '1', '40', '−39', '140', '0', '140'],
            ['t3→t4', '55', '0', '55', '60', '10', '50']
          ],
          caption: '净负荷模式：t2→t3 上调缺额 39 MW'
        },
        {
          type: 'table',
          headers: ['区间', 'F_sup^up', 'R_AGC^up', 'M^up', 'M^down'],
          rows: [
            ['t0→t1', '56', '15', '41', '100'],
            ['t1→t2', '41', '0', '41', '100'],
            ['t2→t3', '1', '20', '−19', '140'],
            ['t3→t4', '55', '45', '10', '60']
          ],
          caption: 'AGC 模式：t2→t3 上调缺额 19 MW'
        },
        {
          type: 'callout',
          tone: 'info',
          title: '两种需求模式的核心区别',
          text: '供给完全相同（F_sup^up = [56,41,1,55]，F_sup^down = [100,115,140,60]），只是需求来源不同。本例最大上调缺额：净负荷 39 MW、AGC 19 MW，都发生在 t2→t3，根因都是 t2 基准 POI = 95 距上限 96 仅剩 1 MW。'
        }
      ]
    },
    {
      id: 'ch3-device',
      title: '3.4 各设备灵活性公式',
      blocks: [
        {
          type: 'h',
          level: 3,
          text: '可控发电（CP / GP / HYDRO）'
        },
        {
          type: 'formula',
          text: 'F_i,t^up   = max(0, min[ P_max − P_t,  R^up × Δt ])\nF_i,t^down = max(0, min[ P_t − P_min,  R^down × Δt ])',
          caption: '出力余量 × 爬坡允许量取小；离线机组仅当允许启动且启动时间 ≤ Δt 才可计入上调'
        },
        {
          type: 'h',
          level: 3,
          text: '风电 / 光伏（WT / PV）'
        },
        {
          type: 'formula',
          text: 'F_re,t^up   = max(0, min[ P_av − P_t,  R^up × Δt ])\nF_re,t^down = max(0, min[ P_t − P_min,  R^down × Δt ])',
          caption: '上调 = 主动限发预留空间；满发时上调为 0。自然波动不计入供给'
        },
        {
          type: 'callout',
          tone: 'warning',
          title: '自然波动 vs 主动调节',
          text: 'ΔP^av = P_{t+1}^av − P_t^av 与预测误差属于需求/风险侧，严禁与供给重复计数。ramp_constraint_on 打开时才应用变化率（WT/PV 默认关，HYDRO 默认开）。'
        },
        {
          type: 'h',
          level: 3,
          text: '储能（ES / FS / CS / PS）'
        },
        {
          type: 'formula',
          text: 'P̄_t = min( P_dis^max,  η_dis × (E_t − E_min) / Δt )\n_P_t = −min( P_ch^max,  (E_max − E_t) / (η_ch × Δt) )\nF^up   = max(0, min[ P̄_t − P_t,  R^up × Δt ])\nF^down = max(0, min[ P_t − _P_t,  R^down × Δt ])',
          caption: '先求下一时段可达功率界（含效率与能量约束），再与爬坡取小'
        },
        {
          type: 'p',
          text: '充电状态时上调空间自然包含「停充转放」；放电状态时下调空间包含「停放转充」。抽水蓄能同式，发电为正、抽水为负。'
        },
        {
          type: 'h',
          level: 3,
          text: '柔性负荷（电解槽 ET 等）'
        },
        {
          type: 'formula',
          text: 'F_L^up   = max(0, min[ L_t − L_min,  R^down × Δt ])    （减负荷 = 系统上调）\nF_L^down = max(0, min[ L_max − L_t,  R^up × Δt ])    （增负荷 = 系统下调）',
          caption: '方向翻转：降低用电提供上调'
        },
        {
          type: 'h',
          level: 3,
          text: '零灵活性组件'
        },
        {
          type: 'table',
          headers: ['组件', 'up / down', '原因'],
          rows: [
            ['ELOAD 刚性电负荷', '0 / 0', '负荷曲线变化进需求，不进供给'],
            ['CHP 热电联产', '0 / 0', '热负荷驱动固定热电比，电功率被唯一确定'],
            ['HS / HLOAD / QLOAD', '0 / 0', '不直接与电母线交换有功']
          ]
        },
        {
          type: 'p',
          text: '失负荷只能作高惩罚松弛，不得计为常见灵活性供给。'
        }
      ]
    },
    {
      id: 'ch3-ui',
      title: '3.5 软件操作路径',
      blocks: [
        {
          type: 'h',
          level: 3,
          text: '配置（创建计算任务时）'
        },
        {
          type: 'p',
          text: '路径：结果分析 / 计算任务页 → 新建仿真计算任务 → 「灵活性评价设置」区块。'
        },
        {
          type: 'table',
          headers: ['配置项', '选项 / 输入', '说明'],
          rows: [
            ['需求来源', '净负荷变化 / AGC目标计划 / 用户自定义', '离网自动隐藏 AGC'],
            ['并网点', 'GRID 组件下拉', '多 GRID 必选；离网显示「无并网点」'],
            ['并网点功率边界', '只读卡片', '接口容量、上送上限、购入下限'],
            ['数值输入方式', '常数 / 导入文件 / 项目边界数据库', '非净负荷模式时'],
            ['AGC 输入', '目标并网功率（kW，正上送）', '常数或时间序列'],
            ['用户自定义', '上/下调需求（kW，非负）', '常数或时间序列']
          ]
        },
        {
          type: 'callout',
          tone: 'tip',
          title: '运行模式说明',
          text: '前端当前固定 operationMode = economic_operation（基准模型始终经济运行），layerId 固定为项目最底层时层。任务默认 flexibility.enabled = true。'
        },
        {
          type: 'h',
          level: 3,
          text: '结果查看'
        },
        {
          type: 'steps',
          items: [
            {
              title: '系统灵活性量化评估',
              text: '顶部配置摘要（需求来源、网络口径、GRID 边界）；全时域指标卡片（最小裕度、最大缺额、缺额电量、达标比例）；需求来源图；上/下调灵活性时序（系统供给/需求/负裕度标红）；贡献度分析与分时贡献堆叠图；可点缺额标记看详情弹窗。'
            },
            {
              title: '设备灵活性量化评估',
              text: '按设备分组的 DeviceFlexibilityChart：上调/下调曲线、系统供给分摊虚线、峰值卡片；GRID 显示「并网边界」徽标与边界空间。'
            },
            {
              title: '实时更新',
              text: '运行中轮询 + WebSocket 增量合并；首次全量、之后按时间增量拉取。'
            }
          ]
        },
        {
          type: 'p',
          text: '时间控制：按仿真日期的日期窗口 + 时间滑块，与需求来源图共享视窗。下调曲线在显示层画在零轴下方，峰值卡片仍显示非负容量。'
        }
      ]
    },
    {
      id: 'ch3-metrics',
      title: '3.6 指标解读',
      blocks: [
        {
          type: 'table',
          headers: ['指标', '含义', '解读要点'],
          rows: [
            ['设备灵活性', '单设备 Δt 内可增/减有功', '功率空间与爬坡/能量双重约束取小'],
            ['设备贡献', '计入系统供给的份额', 'POI 卡时按比例缩小；统计口径非调度指令'],
            ['内部合计', '内部可调设备能力之和', '池子里总共有多少调节力'],
            ['POI 剩余空间', '基准并网功率到接口限值距离', '上调被卡时看它是否远小于内部合计'],
            ['系统供给', 'min(内部合计, POI 空间)', '系统真正能拿出的调节能力'],
            ['瓶颈', 'internal_devices / poi_*_limit', '是设备不够还是并网口不够'],
            ['系统需求', '净负荷变化或 AGC 偏差或用户目标', '同一时刻只计一种需求'],
            ['裕度 margin', '供给 − 需求', '>0 富余；<0 不足（图上标红）'],
            ['缺额 deficit', 'max(0, −margin)', '只在不足时非零'],
            ['充足率', '供给 / 需求', '≥1 满足；需求=0 显示不适用'],
            ['最大缺额', '全时域最差缺额', '与最小裕度配套读'],
            ['缺额电量', 'Σ 缺额 × Δt', '缺口的能量规模'],
            ['达标时段比例', '裕度≥0 时段占比', '>90% 界面绿色；勿用平均充足率代替']
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '结论句式示例'
        },
        {
          type: 'callout',
          tone: 'info',
          title: '可以直接这样写分析',
          text: '「t2→t3 区间上调裕度 −39 MW，最大上调缺额 39 MW；瓶颈为 poi_upper_limit，原因是 t2 基准并网功率 95 MW 已接近上送上限 96 MW。下调方向全时域达标比例 100%，上调方向 75%，缺额电量 39 MWh。」'
        },
        {
          type: 'p',
          text: '灵活性评价的结果适合回答：要不要加储能/柔性负荷、POI 容量够不够、AGC 跟踪有没有风险、哪个时段最紧张、是哪类设备在扛调节。结合第二章的设备模型与第一章的滚动优化流程，即可形成「建模 → 仿真 → 评价 → 配置决策」的完整闭环。'
        }
      ]
    }
  ]
}
