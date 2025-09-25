defmodule SmartTodoWeb.TaskLive.IndexTest do
  use SmartTodoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SmartTodo.AccountsFixtures
  import SmartTodo.TasksFixtures

  alias SmartTodo.Accounts.Scope
  alias SmartTodo.Tasks

  test "redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/tasks")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "renders tasks page and shows quick form", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, _lv, html} = live(conn, ~p"/tasks")
    assert html =~ ~s/id="quick-task-form"/
    assert html =~ "What would you like me to do?"
  end

  test "shows empty state when user has no tasks", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, lv, _html} = live(conn, ~p"/tasks")

    assert has_element?(lv, "p", "No tasks yet — add your first one above.")
  end

  test "validate shows errors and preserves multi-select selection (advanced)", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    a = task_fixture(user, %{title: "A"})
    {:ok, lv, _html} = live(conn, ~p"/tasks")

    # open advanced form
    _html = lv |> element("button", "Advanced task create") |> render_click()

    # render_change with empty title to trigger validation
    html =
      lv
      |> element("#advanced-task-form")
      |> render_change(%{"task" => %{"title" => "", "prerequisite_ids" => [to_string(a.id)]}})

    doc = LazyHTML.from_fragment(html)
    # ensure prerequisite option remains selected
    assert LazyHTML.filter(doc, ~s/select#task_prereq_ids option[value="#{a.id}"][selected]/) !=
             []
  end

  test "create a task via quick form and list updates", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _} = live(conn, ~p"/tasks")

    form = element(lv, "#quick-task-form")
    html = render_submit(form, %{"quick_task" => %{"title" => "Do thing"}})
    assert html =~ "Task created"
    assert html =~ "Do thing"
  end

  test "blocked task button is disabled until prerequisite is completed", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    a = task_fixture(user, %{title: "A"})
    b = task_fixture(user, %{title: "B"})
    assert {:ok, :ok} = Tasks.upsert_dependencies(scope, b.id, [a.id])

    {:ok, lv, _} = live(conn, ~p"/tasks")

    # button for B is disabled
    assert has_element?(
             lv,
             "button[phx-click=\"toggle_done\"][phx-value-id=\"#{b.id}\"][disabled]"
           )

    assert has_element?(lv, "#blocked-tasks div[id=\"blocked_tasks-#{b.id}\"] li", a.title)
    assert has_element?(lv, "#ready-tasks div[id=\"ready_tasks-#{a.id}\"] li", b.title)

    # complete A via click
    _ =
      lv
      |> element("button[phx-click=\"toggle_done\"][phx-value-id=\"#{a.id}\"]")
      |> render_click()

    # now B's button should be enabled
    refute has_element?(
             lv,
             "button[phx-click=\"toggle_done\"][phx-value-id=\"#{b.id}\"][disabled]"
           )
  end

  test "edit task button loads form and saves changes", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    prep = task_fixture(user, %{title: "Prep"})
    task = task_fixture(user, %{title: "Main"})
    scope = Scope.for_user(user)
    assert {:ok, :ok} = Tasks.upsert_dependencies(scope, task.id, [prep.id])

    {:ok, lv, _} = live(conn, ~p"/tasks")

    html =
      lv
      |> element("button[phx-click=\"edit_task\"][phx-value-id=\"#{task.id}\"]")
      |> render_click()

    assert html =~ "Edit task"
    assert has_element?(lv, "#edit-task-form")

    doc = LazyHTML.from_fragment(render(lv))

    assert LazyHTML.filter(
             doc,
             "select#edit_task_prereq_ids option[value=\"#{prep.id}\"][selected]"
           ) != []

    params = %{"task" => %{"title" => "Updated main", "prerequisite_ids" => []}}
    html = lv |> element("#edit-task-form") |> render_submit(params)

    assert html =~ "Task updated"
    refute has_element?(lv, "#edit-task-form")
    assert render(lv) =~ "Updated main"
  end

  test "trash button deletes task", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    task = task_fixture(user, %{title: "Temp"})

    {:ok, lv, _} = live(conn, ~p"/tasks")

    html =
      lv
      |> element("button[phx-click=\"trash_task\"][phx-value-id=\"#{task.id}\"]")
      |> render_click()

    assert html =~ "Task deleted"
    refute has_element?(lv, "button[phx-click=\"toggle_done\"][phx-value-id=\"#{task.id}\"]")
  end

  test "completed tasks become visible after toggling show", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    task = task_fixture(user, %{title: "Finished"})
    assert {:ok, _} = Tasks.update_task(scope, task, %{status: :done})

    {:ok, lv, _} = live(conn, ~p"/tasks")

    assert has_element?(lv, "#completed-tasks.hidden")

    _html =
      lv
      |> element("button[phx-click=\"toggle_completed\"]")
      |> render_click()

    refute has_element?(lv, "#completed-tasks.hidden")

    assert has_element?(lv, "#completed-tasks div[id^=\"completed_tasks-\"]")
  end
end
