#if os(Linux)
import Foundation

@main
enum LinuxMain {
    static func main() {
        print("iPod Converter for Linux — \(IPodModel.allCases.count) models")
    }
}
#endif
