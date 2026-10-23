import Lake
open Lake DSL

package "redlock" where
  -- add package configuration options here

lean_lib «Redlock» where
  -- add library configuration options here

@[default_target]
lean_exe "redlock" where
  root := `Main
