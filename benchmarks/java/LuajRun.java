import org.luaj.vm2.Globals;
import org.luaj.vm2.LuaValue;
import org.luaj.vm2.lib.jse.JsePlatform;

/**
 * Minimal LuaJ file runner for tests and benchmarks:
 *   java -Dluaj.path="$PWD/?.lua;$PWD/tests/?.lua" -cp .:luaj.jar LuajRun script.lua [args...]
 *
 * When the NYRDS/luaj fork jar is on the classpath, the zero-thread fiber
 * library is installed exactly like the Android embedding does
 * (globals.load(new FiberLib())); on the stock luaj jar the reflective lookup
 * fails and the run proceeds on coroutines. FiberLib is loaded reflectively
 * so one compiled artifact runs against both jars. Set -Dluaj.nofiber=true
 * to skip the install and benchmark the fork's coroutine substrate.
 */
public class LuajRun {
    public static void main(String[] args) throws Exception {
        Globals globals = JsePlatform.standardGlobals();
        if (!Boolean.getBoolean("luaj.nofiber")) {
            try {
                Class<?> fiberLib = Class.forName("org.luaj.vm2.lib.fiber.FiberLib");
                globals.load((LuaValue) fiberLib.getDeclaredConstructor().newInstance());
            } catch (ClassNotFoundException e) {
                // stock luaj jar: coroutine-based yields only
            }
        }
        LuaValue chunk = globals.loadfile(args[0]);
        LuaValue[] rest = new LuaValue[args.length - 1];
        for (int i = 1; i < args.length; i++) rest[i - 1] = LuaValue.valueOf(args[i]);
        chunk.invoke(LuaValue.varargsOf(rest));
    }
}
