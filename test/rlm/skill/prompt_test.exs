defmodule RLM.Skill.PromptTest do
  use ExUnit.Case, async: true

  alias RLM.Skill
  alias RLM.Skill.Prompt

  @moduletag :skill

  describe "catalog_section/1" do
    test "returns empty string for empty list" do
      assert Prompt.catalog_section([]) == ""
    end

    test "formats single skill entry" do
      entries = [
        %{name: "pdf-tool", description: "Process PDFs.", path: "/skills/pdf-tool/SKILL.md"}
      ]

      section = Prompt.catalog_section(entries)

      assert section =~ "Available Skills"
      assert section =~ "pdf-tool"
      assert section =~ "Process PDFs."
      assert section =~ "read_file"
    end

    test "formats multiple skill entries" do
      entries = [
        %{name: "alpha", description: "First skill.", path: "/skills/alpha/SKILL.md"},
        %{name: "beta", description: "Second skill.", path: "/skills/beta/SKILL.md"}
      ]

      section = Prompt.catalog_section(entries)

      assert section =~ "alpha"
      assert section =~ "First skill."
      assert section =~ "beta"
      assert section =~ "Second skill."
    end

    test "includes skill paths for read_file activation" do
      entries = [
        %{
          name: "my-skill",
          description: "Desc.",
          path: "/home/user/.rlm/skills/my-skill/SKILL.md"
        }
      ]

      section = Prompt.catalog_section(entries)

      assert section =~ "/home/user/.rlm/skills/my-skill/SKILL.md"
    end
  end

  describe "activation_messages/1" do
    test "returns empty list for no skills" do
      assert Prompt.activation_messages([]) == []
    end

    test "returns user messages with skill body and directory" do
      skill = %Skill{
        name: "test-skill",
        description: "A test.",
        path: "/skills/test-skill/SKILL.md",
        dir: "/skills/test-skill",
        body: "# Instructions\n\nDo the thing."
      }

      [msg] = Prompt.activation_messages([skill])

      assert msg.role == :user
      assert msg.content =~ "Skill activated: test-skill"
      assert msg.content =~ "# Instructions"
      assert msg.content =~ "Do the thing."
      assert msg.content =~ "/skills/test-skill"
    end

    test "handles multiple activated skills" do
      skills = [
        %Skill{
          name: "skill-a",
          description: "First.",
          path: "/a/SKILL.md",
          dir: "/a",
          body: "Body A."
        },
        %Skill{
          name: "skill-b",
          description: "Second.",
          path: "/b/SKILL.md",
          dir: "/b",
          body: "Body B."
        }
      ]

      msgs = Prompt.activation_messages(skills)

      assert length(msgs) == 2
      assert Enum.at(msgs, 0).content =~ "skill-a"
      assert Enum.at(msgs, 0).content =~ "Body A."
      assert Enum.at(msgs, 1).content =~ "skill-b"
      assert Enum.at(msgs, 1).content =~ "Body B."
    end
  end
end
