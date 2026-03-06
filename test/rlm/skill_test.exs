defmodule RLM.SkillTest do
  use ExUnit.Case, async: true

  alias RLM.Skill

  @moduletag :skill

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "rlm_skill_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  defp write_skill(tmp_dir, name, content) do
    skill_dir = Path.join(tmp_dir, name)
    File.mkdir_p!(skill_dir)
    path = Path.join(skill_dir, "SKILL.md")
    File.write!(path, content)
    path
  end

  describe "parse/1" do
    test "parses valid SKILL.md with required fields", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "my-skill", """
        ---
        name: my-skill
        description: A test skill that does things.
        ---
        # Instructions

        Do the thing.
        """)

      assert {:ok, skill} = Skill.parse(path)
      assert skill.name == "my-skill"
      assert skill.description == "A test skill that does things."
      assert skill.path == path
      assert skill.dir == Path.join(tmp_dir, "my-skill")
      assert skill.body =~ "# Instructions"
      assert skill.body =~ "Do the thing."
    end

    test "parses SKILL.md with all optional fields", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "full-skill", """
        ---
        name: full-skill
        description: A fully specified skill.
        license: MIT
        compatibility: Requires git and docker
        metadata:
          author: test-org
          version: "1.0"
        allowed-tools: Bash Read Write
        ---
        Body content here.
        """)

      assert {:ok, skill} = Skill.parse(path)
      assert skill.name == "full-skill"
      assert skill.description == "A fully specified skill."
      assert skill.license == "MIT"
      assert skill.compatibility == "Requires git and docker"
      assert skill.metadata == %{"author" => "test-org", "version" => "1.0"}
      assert skill.allowed_tools == ["Bash", "Read", "Write"]
    end

    test "returns error for missing name field", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "no-name", """
        ---
        description: Missing name field.
        ---
        Body.
        """)

      assert {:error, reason} = Skill.parse(path)
      assert reason =~ "name"
    end

    test "returns error for missing description field", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "no-desc", """
        ---
        name: no-desc
        ---
        Body.
        """)

      assert {:error, reason} = Skill.parse(path)
      assert reason =~ "description"
    end

    test "returns error for missing frontmatter delimiters", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "no-front", """
        # Just markdown

        No frontmatter here.
        """)

      assert {:error, reason} = Skill.parse(path)
      assert reason =~ "frontmatter"
    end

    test "returns error for empty file", %{tmp_dir: tmp_dir} do
      path = write_skill(tmp_dir, "empty", "")
      assert {:error, _reason} = Skill.parse(path)
    end

    test "returns error for nonexistent file" do
      assert {:error, reason} = Skill.parse("/nonexistent/path/SKILL.md")
      assert reason =~ "read"
    end

    test "extracts body markdown after frontmatter", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "body-test", """
        ---
        name: body-test
        description: Test body extraction.
        ---
        Line one.

        Line two.

        ## Section

        More content.
        """)

      assert {:ok, skill} = Skill.parse(path)
      assert skill.body =~ "Line one."
      assert skill.body =~ "Line two."
      assert skill.body =~ "## Section"
      assert skill.body =~ "More content."
      # Body should not contain frontmatter
      refute skill.body =~ "name:"
      refute skill.body =~ "description:"
    end

    test "handles body containing --- separator", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "dash-body", """
        ---
        name: dash-body
        description: Body has dashes.
        ---
        Before separator.

        ---

        After separator.
        """)

      assert {:ok, skill} = Skill.parse(path)
      assert skill.body =~ "Before separator."
      assert skill.body =~ "---"
      assert skill.body =~ "After separator."
    end

    test "parses metadata map correctly", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "meta-skill", """
        ---
        name: meta-skill
        description: Has metadata.
        metadata:
          author: someone
          version: "2.0"
          custom-key: custom-value
        ---
        Body.
        """)

      assert {:ok, skill} = Skill.parse(path)

      assert skill.metadata == %{
               "author" => "someone",
               "version" => "2.0",
               "custom-key" => "custom-value"
             }
    end

    test "parses allowed-tools as list", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "tools-skill", """
        ---
        name: tools-skill
        description: Has allowed tools.
        allowed-tools: Bash(git:*) Read Write
        ---
        Body.
        """)

      assert {:ok, skill} = Skill.parse(path)
      assert skill.allowed_tools == ["Bash(git:*)", "Read", "Write"]
    end

    test "handles description with colon (common YAML edge case)", %{tmp_dir: tmp_dir} do
      path =
        write_skill(tmp_dir, "colon-desc", """
        ---
        name: colon-desc
        description: "Use this skill when: the user asks about PDFs"
        ---
        Body.
        """)

      assert {:ok, skill} = Skill.parse(path)
      assert skill.description == "Use this skill when: the user asks about PDFs"
    end
  end

  describe "validate_name/1" do
    test "accepts valid lowercase name" do
      assert :ok = Skill.validate_name("pdf-processing")
    end

    test "accepts single character name" do
      assert :ok = Skill.validate_name("a")
    end

    test "accepts name with numbers" do
      assert :ok = Skill.validate_name("skill-v2")
    end

    test "rejects uppercase characters" do
      assert {:error, reason} = Skill.validate_name("My-Skill")
      assert reason =~ "lowercase"
    end

    test "rejects leading hyphen" do
      assert {:error, reason} = Skill.validate_name("-skill")
      assert reason =~ "hyphen"
    end

    test "rejects trailing hyphen" do
      assert {:error, reason} = Skill.validate_name("skill-")
      assert reason =~ "hyphen"
    end

    test "rejects consecutive hyphens" do
      assert {:error, reason} = Skill.validate_name("my--skill")
      assert reason =~ "consecutive"
    end

    test "rejects names over 64 characters" do
      long_name = String.duplicate("a", 65)
      assert {:error, reason} = Skill.validate_name(long_name)
      assert reason =~ "64"
    end

    test "rejects empty name" do
      assert {:error, _reason} = Skill.validate_name("")
    end
  end

  describe "catalog_entry/1" do
    test "returns name, description, and path" do
      skill = %Skill{
        name: "test-skill",
        description: "A test skill.",
        path: "/path/to/SKILL.md",
        dir: "/path/to",
        body: "Full body content."
      }

      entry = Skill.catalog_entry(skill)
      assert entry.name == "test-skill"
      assert entry.description == "A test skill."
      assert entry.path == "/path/to/SKILL.md"
      refute Map.has_key?(entry, :body)
    end
  end
end
