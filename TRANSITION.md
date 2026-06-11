
<<SBC execute_script SBC 不是独立执行模式 只是程序替模型轮询 ACC.>>
<<SBC interrupt_flag 提前 return interrupted 状态 跳过了 collect_result.>>
<<SBC 修复 删除 interrupted 提前返回 副作用后继续 poll 自然收集结果同 ACC.>>
<<Eai.Tool.ExecuteScript 热更新 compile_file 但 persistent_term 缓存需清.>>
<<上下文备份 sbc_fix_context.gz 重启后可恢复.>>
