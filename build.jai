// All build configuration stays in Jai; `jacket run` uses this file as its entry point.
#load "src/main.jai";

#scope_file
Build :: #import "Compiler";
Build_Basic :: #import "Basic";
Build_Process :: #import "Process";
Build_Files :: #import "File_Utilities";
Build_String :: #import "String";

using Build_Basic;

build_library_directory :: (formula: string, library: string) -> string {
    result, output, errors, timed_out := Build_Process.run_command("brew", "--prefix", formula,
        capture_and_return_output = true, timeout_ms = 5000);
    defer free(output);
    defer free(errors);
    if timed_out || result.type != .EXITED || result.exit_code != 0 {
        Build.compiler_report(tprint("Cannot locate Homebrew %. Install the native dependencies with `brew install libpq argon2 openssl postgresql@17`, then run `jacket run` again.", formula));
        return "";
    }
    directory := sprint("%/lib", Build_String.trim(output));
    if !Build_Files.file_exists(tprint("%/%", directory, library)) {
        Build.compiler_report(tprint("Missing % in %. Run `brew install %` (or `brew reinstall %` if already installed).", library, directory, formula, formula));
        free(directory);
        return "";
    }
    return directory;
}

#run {
    options := Build.get_build_options();
    imports: [..] string;
    for options.import_path array_add(*imports, it);
    array_add(*imports, "src/modules");
    options.import_path = imports;
    linker_arguments: [..] string;
    for options.additional_linker_arguments array_add(*linker_arguments, it);
    options.output_path = "build";
    options.output_executable_name = "arabic";
    #if OS == .MACOS {
        formulas: [] string = .["libpq", "argon2", "openssl"];
        libraries: [] string = .["libpq.dylib", "libargon2.dylib", "libcrypto.dylib"];
        for formula, index: formulas {
            directory := build_library_directory(formula, libraries[index]);
            if directory.count == 0 return;
            // Let the platform linker select the dynamic system library. Registering this as
            // a compiler library directory makes Jacket 0.25 prefer Homebrew's static archive.
            array_add(*linker_arguments, sprint("-L%", directory));
        }
    }
    options.additional_linker_arguments = linker_arguments;
    Build.set_build_options(options);
}
