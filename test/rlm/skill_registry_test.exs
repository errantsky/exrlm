defmodule RLM.SkillRegistryTest do
  use ExUnit.Case, async: true

  alias RLM.SkillRegistry

  @moduletag :skill

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "rlm_registry_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  defp write_skill(base, name, opts \\ []) do
    description = Keyword.get(opts, :description, "A skill called #{name}.")
    body = Keyword.get(opts, :body, "Instructions for #{name}.")

    skill_dir = Path.join(base, name)
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---
    #{body}
    """)
  end

  defp start_registry(paths) do
    name = :"skill_registry_#{:erlang.unique_integer([:positive])}"
    opts = [skill_paths: paths, name: name]
    start_supervised!({SkillRegistry, opts})
  end

  describe "init and discovery" do
    test "starts with empty catalog when no skill directories exist", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "empty")
      File.mkdir_p!(empty_dir)

      pid = start_registry([empty_dir])
      assert SkillRegistry.catalog(pid) == []
    end

    test "discovers skills in configured paths", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "alpha")
      write_skill(tmp_dir, "beta")

      pid = start_registry([tmp_dir])
      catalog = SkillRegistry.catalog(pid)

      assert length(catalog) == 2
      names = Enum.map(catalog, & &1.name)
      assert "alpha" in names
      assert "beta" in names
    end

    test "project skills override user skills with same name", %{tmp_dir: tmp_dir} do
      user_dir = Path.join(tmp_dir, "user_skills")
      project_dir = Path.join(tmp_dir, "project_skills")
      File.mkdir_p!(user_dir)
      File.mkdir_p!(project_dir)

      write_skill(user_dir, "shared", description: "User version.")
      write_skill(project_dir, "shared", description: "Project version.")

      # Project path comes last → wins
      pid = start_registry([user_dir, project_dir])

      assert {:ok, skill} = SkillRegistry.get(pid, "shared")
      assert skill.description == "Project version."
    end

    test "records parse errors without crashing", %{tmp_dir: tmp_dir} do
      # Create a skill directory with invalid SKILL.md
      bad_dir = Path.join(tmp_dir, "bad-skill")
      File.mkdir_p!(bad_dir)
      File.write!(Path.join(bad_dir, "SKILL.md"), "no frontmatter here")

      # Also create a valid skill
      write_skill(tmp_dir, "good-skill")

      pid = start_registry([tmp_dir])

      # Good skill is discovered
      catalog = SkillRegistry.catalog(pid)
      assert length(catalog) == 1
      assert hd(catalog).name == "good-skill"

      # Error is recorded
      errors = SkillRegistry.errors(pid)
      assert length(errors) >= 1
      assert Enum.any?(errors, fn {path, _reason} -> path =~ "bad-skill" end)
    end

    test "ignores directories without SKILL.md", %{tmp_dir: tmp_dir} do
      # Just a random directory
      File.mkdir_p!(Path.join(tmp_dir, "not-a-skill"))
      File.write!(Path.join(tmp_dir, "not-a-skill/README.md"), "Not a skill.")

      # A real skill
      write_skill(tmp_dir, "real-skill")

      pid = start_registry([tmp_dir])
      catalog = SkillRegistry.catalog(pid)

      assert length(catalog) == 1
      assert hd(catalog).name == "real-skill"
    end

    test "handles nonexistent scan paths gracefully", %{tmp_dir: tmp_dir} do
      pid = start_registry([Path.join(tmp_dir, "does-not-exist")])
      assert SkillRegistry.catalog(pid) == []
    end
  end

  describe "catalog/1" do
    test "returns sorted list of catalog entries", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "zulu")
      write_skill(tmp_dir, "alpha")
      write_skill(tmp_dir, "mike")

      pid = start_registry([tmp_dir])
      catalog = SkillRegistry.catalog(pid)

      names = Enum.map(catalog, & &1.name)
      assert names == ["alpha", "mike", "zulu"]
    end

    test "returns empty list when no skills exist", %{tmp_dir: tmp_dir} do
      pid = start_registry([tmp_dir])
      assert SkillRegistry.catalog(pid) == []
    end
  end

  describe "get/2" do
    test "returns {:ok, skill} for existing skill", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "my-skill", body: "Custom body.")

      pid = start_registry([tmp_dir])
      assert {:ok, skill} = SkillRegistry.get(pid, "my-skill")
      assert skill.name == "my-skill"
      assert skill.body =~ "Custom body."
    end

    test "returns :error for nonexistent skill", %{tmp_dir: tmp_dir} do
      pid = start_registry([tmp_dir])
      assert :error = SkillRegistry.get(pid, "nope")
    end
  end

  describe "names/1" do
    test "returns sorted list of skill names", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "beta")
      write_skill(tmp_dir, "alpha")

      pid = start_registry([tmp_dir])
      assert SkillRegistry.names(pid) == ["alpha", "beta"]
    end
  end

  describe "reload/1" do
    test "picks up newly added skills", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "original")

      pid = start_registry([tmp_dir])
      assert length(SkillRegistry.catalog(pid)) == 1

      # Add a new skill on disk
      write_skill(tmp_dir, "added")
      SkillRegistry.reload(pid)

      # Give cast time to process
      :sys.get_state(pid)

      assert length(SkillRegistry.catalog(pid)) == 2
      names = SkillRegistry.names(pid)
      assert "added" in names
    end

    test "removes deleted skills", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "keep-me")
      write_skill(tmp_dir, "delete-me")

      pid = start_registry([tmp_dir])
      assert length(SkillRegistry.catalog(pid)) == 2

      # Delete skill on disk
      File.rm_rf!(Path.join(tmp_dir, "delete-me"))
      SkillRegistry.reload(pid)
      :sys.get_state(pid)

      names = SkillRegistry.names(pid)
      assert "keep-me" in names
      refute "delete-me" in names
    end

    test "updates modified skills", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "mutable", description: "Version 1.")

      pid = start_registry([tmp_dir])
      assert {:ok, skill} = SkillRegistry.get(pid, "mutable")
      assert skill.description == "Version 1."

      # Overwrite SKILL.md
      write_skill(tmp_dir, "mutable", description: "Version 2.")
      SkillRegistry.reload(pid)
      :sys.get_state(pid)

      assert {:ok, skill} = SkillRegistry.get(pid, "mutable")
      assert skill.description == "Version 2."
    end
  end

  describe "reload/2" do
    test "replaces paths and rescans", %{tmp_dir: tmp_dir} do
      dir_a = Path.join(tmp_dir, "dir_a")
      dir_b = Path.join(tmp_dir, "dir_b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      write_skill(dir_a, "skill-a")
      write_skill(dir_b, "skill-b")

      pid = start_registry([dir_a])
      assert SkillRegistry.names(pid) == ["skill-a"]

      # Reload with different paths
      SkillRegistry.reload(pid, [dir_b])
      :sys.get_state(pid)

      assert SkillRegistry.names(pid) == ["skill-b"]
    end
  end
end
