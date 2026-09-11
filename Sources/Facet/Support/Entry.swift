import Foundation

@main
struct Entry {
    static func main() {
        if CommandLine.arguments.contains("--serve") {
            setvbuf(stdout, nil, _IOLBF, 0)
            ServeCommand.run(args: CommandLine.arguments)
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            setvbuf(stdout, nil, _IOLBF, 0)   // keep output if a run aborts
            SelfTest.run(args: CommandLine.arguments)
            return
        }
        FacetApp.main()
    }
}
