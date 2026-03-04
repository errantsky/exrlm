defmodule RLM.SkillRegistryTest do
  use ExUnit.Case, async: true

  alias RLM.SkillRegistry

  setup do
    dir = Path.join(System.tmp_dir!(), "rlm_skill_reg_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_skill(dir, name, description) do
    skill_dir = Path.join(dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    version: "1.0"
    ---

    # #{name} Instructions

    Do the #{name} thing.
    """)
  end

  describe "discover/1" do
    test "discovers skills from a directory", %{dir: dir} do
      write_skill(dir, "alpha", "Alpha skill")
      write_skill(dir, "beta", "Beta skill")

      skills = SkillRegistry.discover([dir])

      assert map_size(skills) == 2
      assert skills["alpha"].name == "alpha"
      assert skills["alpha"].description == "Alpha skill"
      assert skills["alpha"].loaded? == false
      assert skills["beta"].name == "beta"
    end

    test "first-found wins on name collision", %{dir: dir} do
      high_priority = Path.join(dir, "high")
      low_priority = Path.join(dir, "low")
      File.mkdir_p!(high_priority)
      File.mkdir_p!(low_priority)

      write_skill(high_priority, "conflict", "High priority version")
      write_skill(low_priority, "conflict", "Low priority version")

      skills = SkillRegistry.discover([high_priority, low_priority])

      assert skills["conflict"].description == "High priority version"
    end

    test "skips invalid SKILL.md files gracefully", %{dir: dir} do
      write_skill(dir, "valid", "Valid skill")

      # Create an invalid skill
      bad_dir = Path.join(dir, "broken")
      File.mkdir_p!(bad_dir)
      File.write!(Path.join(bad_dir, "SKILL.md"), "no frontmatter here")

      skills = SkillRegistry.discover([dir])

      assert map_size(skills) == 1
      assert skills["valid"].name == "valid"
    end

    test "returns empty map for nonexistent path" do
      skills = SkillRegistry.discover(["/nonexistent/path"])
      assert skills == %{}
    end

    test "discovers bundled dialectic skill" do
      bundled = Application.app_dir(:rlm, "priv/skills")
      skills = SkillRegistry.discover([bundled])

      assert Map.has_key?(skills, "dialectic")
      assert skills["dialectic"].description =~ "Hegelian"
    end
  end

  describe "summaries/1" do
    test "returns sorted {name, description} tuples", %{dir: dir} do
      write_skill(dir, "zebra", "Last alphabetically")
      write_skill(dir, "alpha", "First alphabetically")

      skills = SkillRegistry.discover([dir])
      result = SkillRegistry.summaries(skills)

      assert result == [
               {"alpha", "First alphabetically"},
               {"zebra", "Last alphabetically"}
             ]
    end

    test "returns empty list for empty map" do
      assert SkillRegistry.summaries(%{}) == []
    end
  end

  describe "activate/2" do
    test "loads full instructions for a discovered skill", %{dir: dir} do
      write_skill(dir, "loadable", "Will load")

      skills = SkillRegistry.discover([dir])
      assert skills["loadable"].loaded? == false

      assert {:ok, loaded, updated_skills} = SkillRegistry.activate(skills, "loadable")
      assert loaded.loaded? == true
      assert loaded.instructions =~ "Do the loadable thing"
      assert updated_skills["loadable"].loaded? == true
    end

    test "is idempotent for already-loaded skills", %{dir: dir} do
      write_skill(dir, "loaded", "Already loaded")

      skills = SkillRegistry.discover([dir])
      {:ok, first, skills} = SkillRegistry.activate(skills, "loaded")
      {:ok, second, _skills} = SkillRegistry.activate(skills, "loaded")

      assert first.instructions == second.instructions
    end

    test "returns error for unknown skill" do
      assert {:error, "Skill not found: unknown"} =
               SkillRegistry.activate(%{}, "unknown")
    end
  end

  describe "default_paths/2" do
    test "includes bundled skills path" do
      paths = SkillRegistry.default_paths(nil, "/tmp/test")
      bundled = Application.app_dir(:rlm, "priv/skills")
      assert bundled in paths
    end

    test "includes project skills path relative to cwd" do
      paths = SkillRegistry.default_paths(nil, "/tmp/test")
      assert "/tmp/test/skills" in paths
    end

    test "includes user skills path" do
      paths = SkillRegistry.default_paths(nil, "/tmp/test")
      user_dir = Path.expand("~/.rlm/skills")
      assert user_dir in paths
    end
  end
end
