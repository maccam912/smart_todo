defmodule SmartTodo.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :smart_todo

  def migrate do
    load_app()

    for repo <- repos() do
      create_db_if_not_exists(repo)
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def create_db_if_not_exists(repo) do
    case repo.__adapter__().storage_up(repo.config()) do
      :ok ->
        IO.puts("Database created successfully")

      {:error, :already_up} ->
        IO.puts("Database already exists")

      {:error, term} when is_binary(term) ->
        IO.puts("Error creating database: #{term}")

      {:error, term} ->
        IO.puts("Error creating database: #{inspect(term)}")
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
