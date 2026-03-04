defmodule RLM.SkillTest do
  use ExUnit.Case, async: true

  alias RLM.Skill

  setup do
    dir = Path.join(System.tmp_dir!(), "rlm_skill_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_skill(dir, name, content) do
    skill_dir = Path.join(dir, name)
    File.mkdir_p!(skill_dir)
    path = Path.join(skill_dir, "SKILL.md")
    File.write!(path, content)
    path
  end

  describe "parse_file/1" do
    test "parses valid SKILL.md with all fields", %{dir: dir} do
      path =
        write_skill(dir, "test-skill", """
        ---
        name: test-skill
        description: A test skill for unit testing
        version: "1.0"
        license: MIT
        ---

        # Test Skill Instructions

        Do the thing step by step.
        """)

      assert {:ok, skill} = Skill.parse_file(path)
      assert skill.name == "test-skill"
      assert skill.description == "A test skill for unit testing"
      assert skill.version == "1.0"
      assert skill.license == "MIT"
      assert skill.instructions =~ "Do the thing step by step"
      assert skill.loaded? == true
      assert skill.path == path
    end

    test "parses minimal SKILL.md (name + description only)", %{dir: dir} do
      path =
        write_skill(dir, "minimal", """
        ---
        name: minimal
        description: Minimal skill
        ---

        Just do it.
        """)

      assert {:ok, skill} = Skill.parse_file(path)
      assert skill.name == "minimal"
      assert skill.description == "Minimal skill"
      assert skill.version == nil
      assert skill.license == nil
      assert skill.instructions == "Just do it."
    end

    test "handles quoted strings in frontmatter", %{dir: dir} do
      path =
        write_skill(dir, "quoted", """
        ---
        name: quoted-skill
        description: "A skill with: colons in description"
        version: '2.0'
        ---

        Instructions here.
        """)

      assert {:ok, skill} = Skill.parse_file(path)
      assert skill.description == "A skill with: colons in description"
      assert skill.version == "2.0"
    end

    test "handles metadata map", %{dir: dir} do
      path =
        write_skill(dir, "with-meta", """
        ---
        name: with-meta
        description: Skill with metadata
        metadata:
          author: Test Author
          phases: 7
        ---

        Instructions.
        """)

      assert {:ok, skill} = Skill.parse_file(path)
      assert skill.metadata == %{"author" => "Test Author", "phases" => "7"}
    end

    test "returns error for missing name", %{dir: dir} do
      path =
        write_skill(dir, "no-name", """
        ---
        description: No name field
        ---

        Instructions.
        """)

      assert {:error, "Missing required field: name"} = Skill.parse_file(path)
    end

    test "returns error for missing description", %{dir: dir} do
      path =
        write_skill(dir, "no-desc", """
        ---
        name: no-desc
        ---

        Instructions.
        """)

      assert {:error, "Missing required field: description"} = Skill.parse_file(path)
    end

    test "returns error for missing frontmatter", %{dir: dir} do
      path =
        write_skill(dir, "no-front", """
        # Just markdown, no frontmatter

        Some content.
        """)

      assert {:error, "Missing YAML frontmatter" <> _} = Skill.parse_file(path)
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = Skill.parse_file("/nonexistent/SKILL.md")
    end
  end

  describe "parse_metadata/1" do
    test "loads only frontmatter, not instructions", %{dir: dir} do
      path =
        write_skill(dir, "meta-only", """
        ---
        name: meta-only
        description: Metadata only loading
        ---

        These instructions should NOT be loaded.
        """)

      assert {:ok, skill} = Skill.parse_metadata(path)
      assert skill.name == "meta-only"
      assert skill.description == "Metadata only loading"
      assert skill.instructions == nil
      assert skill.loaded? == false
    end
  end

  describe "load_instructions/1" do
    test "populates instructions for metadata-only skill", %{dir: dir} do
      path =
        write_skill(dir, "loadable", """
        ---
        name: loadable
        description: Will load instructions later
        ---

        # Full Instructions

        Step 1: Do this.
        Step 2: Do that.
        """)

      {:ok, metadata_skill} = Skill.parse_metadata(path)
      assert metadata_skill.loaded? == false
      assert metadata_skill.instructions == nil

      assert {:ok, loaded_skill} = Skill.load_instructions(metadata_skill)
      assert loaded_skill.loaded? == true
      assert loaded_skill.instructions =~ "Step 1: Do this"
      assert loaded_skill.name == "loadable"
    end

    test "is idempotent for already-loaded skill", %{dir: dir} do
      path =
        write_skill(dir, "already", """
        ---
        name: already
        description: Already loaded
        ---

        Instructions here.
        """)

      {:ok, skill} = Skill.parse_file(path)
      assert skill.loaded? == true

      assert {:ok, ^skill} = Skill.load_instructions(skill)
    end
  end
end
