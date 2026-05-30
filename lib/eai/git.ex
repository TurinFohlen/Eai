defmodule Eai.Git do
  @moduledoc "Git 仓库管理辅助函数"

  defp shared_repo_path do
    sandbox = Application.fetch_env!(:eai, :sandbox)
    case Keyword.get(sandbox, :shared_repo_path) do
      nil ->
        work_dir_root = Keyword.fetch!(sandbox, :work_dir_root)
        Path.join(work_dir_root, "shared.git")
      path ->
        path
    end
  end

  def init_shared_repo do
    path = shared_repo_path()
    if File.dir?(path) do
      {:ok, :already_exists}
    else
      File.mkdir_p!(Path.dirname(path))
      case System.cmd("git", ["init", "--bare", path]) do
        {_, 0} ->
          File.write!(Path.join(path, "description"), "EAI shared repository for agent collaboration\n")
          {:ok, :created}
        {error, _} ->
          {:error, error}
      end
    end
  end

  def get_shared_repo_path, do: shared_repo_path()
end