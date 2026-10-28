// The program Vektor starts. Everything the plugin does is in Sources/BoardPlugin.
import BoardPlugin
import VektorPlugin

setup(Plugin(), options: BoardController.Options(remoteAutoSync: .standard)).run()
