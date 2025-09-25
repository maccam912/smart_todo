dotenv_path = Path.expand(".env", File.cwd!())

if File.exists?(dotenv_path) do
  dotenv_path
  |> File.stream!()
  |> Stream.map(&String.trim/1)
  |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(String.trim(key), String.trim(value))
      _ -> :noop
    end
  end)
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(SmartTodo.Repo, :manual)
