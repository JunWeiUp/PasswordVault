// swift-tools-version: 5.9
import PackageDescription
let package=Package(name:"PeerFixture",platforms:[.macOS(.v13)],dependencies:[.package(path:"CommonRelay")],targets:[.executableTarget(name:"PeerFixture",dependencies:[.product(name:"CommonRelay",package:"CommonRelay")],path:"Sources")])
