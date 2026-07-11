%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "priv/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      parse_timeout: 5000,
      color: true
    }
  ]
}
