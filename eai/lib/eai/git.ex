defmodule Eai.Git do
  @moduledoc "Git 仓库管理辅助函数"

  @shared_repo_path "/home/eai_agents/shared.git"

  def shared_repo_path, do: @shared_repo_path

  def init_shared_repo do
    if File.dir?(@shared_repo_path) do
      {:ok, :already_exists}
    else
      # 创建父目录
      File.mkdir_p!(Path.dirname(@shared_repo_path))
      # 初始化裸仓库
      case System.cmd("git", ["init", "--bare", @shared_repo_path]) do
        {_, 0} ->
          # 可选：写入描述文件
          File.write!(Path.join(@shared_repo_path, "description"), "EAI shared repository for agent collaboration\n")
          {:ok, :created}
        {error, _} ->
          {:error, error}
      end
    end
  end
end
