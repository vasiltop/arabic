// All build configuration stays in Jai; `jacket run` uses this file as its entry point.
#load "src/main.jai";

#scope_file
Build :: #import "Compiler";
Build_Basic :: #import "Basic";
using Build_Basic;

#run {
    options := Build.get_build_options();
    imports: [..] string;
    for options.import_path array_add(*imports, it);
    array_add(*imports, "src/modules");
    options.import_path = imports;
    options.output_path = "build";
    options.output_executable_name = "arabic";
    Build.set_build_options(options);
}
