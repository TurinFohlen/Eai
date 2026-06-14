
<<SBC execute_script SBC 不是独立执行模式 只是程序替模型轮询 ACC.>>
<<SBC interrupt_flag 提前 return interrupted 状态 跳过了 collect_result.>>
<<SBC 修复 删除 interrupted 提前返回 副作用后继续 poll 自然收集结果同 ACC.>>
<<Eai.Tool.ExecuteScript 热更新 compile_file 但 persistent_term 缓存需清.>>
<<上下文备份 sbc_fix_context.gz 重启后可恢复.>>

## GLM-5.1 Models Added

> 2026-06-14

### 官方直连

```
<< glm_5_1, provider, zhipu_official >>
<< glm_5_1, url, "https://open.bigmodel.cn/api/paas/v4/chat/completions" >>
<< glm_5_1, api_key_env, ZHIPU_API_KEY >>
<< glm_5_1, timeout, 300_000 >>
<< glm_5_1, config_file, config/models/glm_5_1.exs >>
```

### 星辰AI中转

```
<< xingchen_glm_5_1, provider, xingchen_ai_proxy >>
<< xingchen_glm_5_1, url, "https://ai.centos.hk/v1/chat/completions" >>
<< xingchen_glm_5_1, api_key_env, XINGCHEN_API_KEY >>
<< xingchen_glm_5_1, timeout, 600_000 >>
<< xingchen_glm_5_1, config_file, config/models/xingchen_glm_5_1.exs >>
```

### CDN options (星辰)

```
<< xingchen_cdn, cloudflare, "https://ai.centos.hk" >>
<< xingchen_cdn, edge_one, "https://api.centos.hk" >>
<< xingchen_cdn, multi_wan, "https://frapi.centos.hk" >>
```

### Subagent 验证

> 2026-06-14 call_subagent(model: :xingchen_glm_5_1) → Status 200，星辰后台扣费 2 分钱。
> 回复内容即使像 Momoka 口吻，是 system prompt 默认人格，非 fallback。

```
<< call_subagent, verified_with, xingchen_glm_5_1 >>
<< xingchen_glm_5_1, verified_by, subagent_call_20260614 >>
<< subagent_model_routing, works_correctly, confirmed_by_token_usage >>
```

### 关键教训

```
<< model_config_new_file, takes_effect, on_vm_restart >>
<< model_config_new_file, does_NOT_take_effect, at_runtime_without_reload_endpoint >>
<< subagent_persona, looks_like_momoka, due_to_default_system_prompt >>
<< subagent_persona, not_indicative_of, model_fallback >>
```
