
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
<< model_config_new_file, does_NOT_take_effect, at_runtime_without_reload_endpoint >>  # FIXED 2026-06-16: hub_reload now reloads models + cards
<< subagent_persona, looks_like_momoka, due_to_default_system_prompt >>
<< subagent_persona, not_indicative_of, model_fallback >>
```

```
<< hub_reload, now_reloads, models_and_cards_in_addition_to_hooks >>
<< model_config_new_file, takes_effect, at_runtime_via_hub_reload >>
<< hub_reload, calls, Eai_Models_reload >>
<< hub_reload, calls, Eai_Card_reload >>
<< fix, applied, 2026-06-16 >>
```

```
<< converse_adapter, now_implements, sigv4_signing >>
<< sigv4, uses, aws_credentials_from_env >>
<< sigv4, required_env_vars, AWS_ACCESS_KEY_ID_and_AWS_SECRET_ACCESS_KEY >>
<< sigv4, optional_env_vars, AWS_SESSION_TOKEN_and_AWS_REGION >>
<< model_config, supports, region_field_for_converse_provider >>
<< Eai_Models_to_run_opts, now_includes, region >>
<< Eai_LLM_Direct_adapter_opts, now_includes, region >>
<< converse_sigv4, implemented, 2026-06-16 >>
```

```
<< tool_telemetry_events, were_duplicated_between, Direct_and_Hub >>
<< Hub_telemetry_events, now_prefixed_with, hub_ >>
<< [:eai,:tool,:pre], renamed_to, [:eai,:tool,:hub_pre]_in_Hub >>
<< [:eai,:tool,:post], renamed_to, [:eai,:tool,:hub_post]_in_Hub >>
<< [:eai,:tool,:blocked], renamed_to, [:eai,:tool,:hub_blocked]_in_Hub >>
<< telemetry_namespace_fix, applied, 2026-06-16 >>
```
