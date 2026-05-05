defmodule Wymcp.MixProject do
  use Mix.Project

  @source_url "https://github.com/kristiangronberg/wymcp"

  def project do
    [
      app: :wymcp,
      version: "0.4.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description: "Model Context Protocol server library for Elixir with Plug integration",
      package: package(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        flags: [
          :unmatched_returns,
          :error_handling,
          :underspecs
        ],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true,
        format: "dialyxir"
      ],
      name: "Wymcp",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: [
        main: "readme",
        api_reference: false,
        formatters: ["html"],
        before_closing_head_tag: &docs_before_closing_head_tag/1,
        before_closing_body_tag: &docs_before_closing_body_tag/1,
        extras: [{"readme.md", title: "README"}] ++ Path.wildcard("docs/*.md"),
        groups_for_extras: []
      ]
    ]
  end

  def application do
    [
      mod: {Wymcp.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CLAUDE.md)
    ]
  end

  defp aliases do
    [
      "dialyzer.watch": fn _args -> Mix.Task.run("dialyzer", []) end
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:jsv, "~> 0.16"},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false},
      {:plug, "~> 1.15"}
    ]
  end

  defp docs_before_closing_body_tag(:html), do: ""
  defp docs_before_closing_body_tag(:epub), do: ""

  defp docs_before_closing_head_tag(:html) do
    """
    <script>
      window.addEventListener("exdoc:loaded", () => {
        document.querySelectorAll('[data-toc]').forEach(tocContainer => {
          const content = tocContainer.closest('.content-inner') || document.querySelector('.content-inner');
          const headings = content.querySelectorAll('h2, h3, h4');

           // Filter out headings inside admonitions (sections with class "admonition")
          const filteredHeadings = Array.from(headings).filter(heading => {
            return !heading.closest('.admonition');
          });

          if (filteredHeadings.length === 0) return;

          const toc = document.createElement('nav');
          toc.className = 'toc';

          // Add "Table of Contents" heading
          const tocHeading = document.createElement('h3');
          tocHeading.textContent = 'Table of Contents';
          tocHeading.className = 'toc-heading';
          toc.appendChild(tocHeading);

          const list = document.createElement('ul');

          filteredHeadings.forEach(heading => {
            const li = document.createElement('li');
            li.className = `toc-${heading.tagName.toLowerCase()}`;
            const link = document.createElement('a');
            link.href = '#' + heading.id;
            link.textContent = heading.textContent;
            li.appendChild(link);
            list.appendChild(li);
          });

          toc.appendChild(list);
          tocContainer.replaceWith(toc);
        });
      });
    </script>

    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
    <script>
    window.addEventListener("exdoc:loaded", () => {
    if (typeof mermaid === "undefined") {
      // mermaid.min.js hasn't executed yet — wait and retry
      const waitForMermaid = setInterval(() => {
        if (typeof mermaid !== "undefined") {
          clearInterval(waitForMermaid);
          initMermaid();
        }
      }, 50);
    } else {
      initMermaid();
    }

    function initMermaid() {
      mermaid.initialize({
        startOnLoad: false,
        theme: document.body.className.includes("dark") ? "dark" : "default"
      });

      let id = 0;
      for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
        const preEl = codeEl.parentElement;
        const graphDefinition = codeEl.textContent;
        const graphEl = document.createElement("div");
        const graphId = "mermaid-graph-" + id++;
        mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
          graphEl.innerHTML = svg;
          bindFunctions?.(graphEl);
          preEl.insertAdjacentElement("afterend", graphEl);
          preEl.remove();
        }).catch((error) => {
          console.error("Mermaid render failed for " + graphId + ":", error);
          preEl.style.borderLeft = "4px solid #e74c3c";
          preEl.title = "Mermaid diagram failed to render";
        });
      }
    }
    });
    </script>

    <script defer src="https://cdn.jsdelivr.net/npm/vega@5.20.2"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/vega-lite@5.1.1"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/vega-embed@6.18.2"></script>
    <script>
      window.addEventListener("exdoc:loaded", () => {
        for (const codeEl of document.querySelectorAll("pre code.vega-lite")) {
          try {
            const preEl = codeEl.parentElement;
            const spec = JSON.parse(codeEl.textContent);
            const plotEl = document.createElement("div");
            preEl.insertAdjacentElement("afterend", plotEl);
            vegaEmbed(plotEl, spec);
            preEl.remove();
          } catch (error) {
            console.log("Failed to render Vega-Lite plot: " + error)
          }
        }
      });
    </script>

    <link rel="stylesheet" href="assets/css/tailwind.css">
    <link rel="stylesheet" href="assets/css/custom.css">
    """
  end

  defp docs_before_closing_head_tag(:epub), do: ""
end
