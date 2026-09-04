import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.List;

/**
 * Java 8-compatible JVM workload for testing local JVM monitoring.
 *
 * Runs until Ctrl+C.
 * Allocates modest amounts of heap, retains them temporarily,
 * and periodically releases older allocations so normal GC activity
 * can be observed by external JVM tools.
 */
public class JvmScopeTestJava8 {

    private static final int OBJECT_SIZE_KB = 64;
    private static final int OBJECTS_PER_BATCH = 16;
    private static final int MAX_RETAINED_BATCHES = 40;
    private static final int BATCHES_TO_RELEASE = 20;
    private static final long LOOP_DELAY_MS = 500L;

    public static void main(String[] args) throws Exception {
        List<List<byte[]>> retained = new ArrayList<List<byte[]>>();
        long cycle = 0L;

        String runtimeName = ManagementFactory.getRuntimeMXBean().getName();

        System.out.println("JvmScopeTestJava8 is running.");
        System.out.println("JVM: " + runtimeName);
        System.out.println("Press Ctrl+C to stop.");
        System.out.println();

        while (true) {
            cycle++;

            List<byte[]> batch = new ArrayList<byte[]>();

            for (int i = 0; i < OBJECTS_PER_BATCH; i++) {
                byte[] data = new byte[OBJECT_SIZE_KB * 1024];

                // Touch the memory so the allocation is actually used.
                data[0] = (byte) cycle;
                data[data.length - 1] = (byte) i;

                batch.add(data);
            }

            retained.add(batch);

            if (retained.size() > MAX_RETAINED_BATCHES) {
                int releaseCount = Math.min(BATCHES_TO_RELEASE, retained.size());

                for (int i = 0; i < releaseCount; i++) {
                    retained.remove(0);
                }

                System.out.println(
                    "Cycle " + cycle +
                    ": released " + releaseCount +
                    " old batches; retained=" + retained.size()
                );
            }

            if (cycle % 5L == 0L) {
                Runtime runtime = Runtime.getRuntime();

                long usedMb =
                    (runtime.totalMemory() - runtime.freeMemory())
                    / (1024L * 1024L);

                long committedMb =
                    runtime.totalMemory()
                    / (1024L * 1024L);

                long maxMb =
                    runtime.maxMemory()
                    / (1024L * 1024L);

                long retainedApproxMb =
                    ((long) retained.size()
                        * OBJECTS_PER_BATCH
                        * OBJECT_SIZE_KB)
                    / 1024L;

                System.out.println(
                    "Cycle " + cycle +
                    ": retained batches=" + retained.size() +
                    ", retained approx=" + retainedApproxMb + " MB" +
                    ", heap used=" + usedMb + " MB" +
                    ", committed=" + committedMb + " MB" +
                    ", max=" + maxMb + " MB"
                );
            }

            Thread.sleep(LOOP_DELAY_MS);
        }
    }
}
