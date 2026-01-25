package com.tigerbeetle;

import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.nio.file.Path;

/**
 * Panama FFI-based native client for TigerBeetle.
 * Requires JDK 22+ (Foreign Function & Memory API).
 *
 * This is an alternative to the JNI-based NativeClient, providing:
 * - No native glue code needed
 * - Better performance (JIT can inline across FFI boundary)
 * - Safer memory management with Arena
 */
final class PanamaClient implements AutoCloseable {

    private static final Linker LINKER = Linker.nativeLinker();
    private static final SymbolLookup LIB;

    // tb_client_t is an opaque struct with 4 x uint64_t = 32 bytes
    private static final long TB_CLIENT_SIZE = 32;
    private static final long TB_CLIENT_ALIGNMENT = 8;

    // tb_packet_t layout
    private static final StructLayout TB_PACKET_LAYOUT = MemoryLayout.structLayout(
        ValueLayout.ADDRESS.withName("user_data"),
        ValueLayout.ADDRESS.withName("data"),
        ValueLayout.JAVA_INT.withName("data_size"),
        ValueLayout.JAVA_SHORT.withName("user_tag"),
        ValueLayout.JAVA_BYTE.withName("operation"),
        ValueLayout.JAVA_BYTE.withName("status"),
        MemoryLayout.sequenceLayout(64, ValueLayout.JAVA_BYTE).withName("opaque")
    );

    // Function descriptors for C API
    private static final FunctionDescriptor TB_CLIENT_INIT_DESC = FunctionDescriptor.of(
        ValueLayout.JAVA_INT,           // return: TB_INIT_STATUS
        ValueLayout.ADDRESS,            // tb_client_t *client_out
        ValueLayout.ADDRESS,            // const uint8_t cluster_id[16]
        ValueLayout.ADDRESS,            // const char *address_ptr
        ValueLayout.JAVA_INT,           // uint32_t address_len
        ValueLayout.JAVA_LONG,          // uintptr_t completion_ctx
        ValueLayout.ADDRESS             // completion_callback function pointer
    );

    private static final FunctionDescriptor TB_CLIENT_SUBMIT_DESC = FunctionDescriptor.of(
        ValueLayout.JAVA_INT,           // return: TB_CLIENT_STATUS
        ValueLayout.ADDRESS,            // tb_client_t *client
        ValueLayout.ADDRESS             // tb_packet_t *packet
    );

    private static final FunctionDescriptor TB_CLIENT_DEINIT_DESC = FunctionDescriptor.of(
        ValueLayout.JAVA_INT,           // return: TB_CLIENT_STATUS
        ValueLayout.ADDRESS             // tb_client_t *client
    );

    // Completion callback descriptor:
    // void (*)(uintptr_t ctx, tb_packet_t* packet, uint64_t timestamp, const uint8_t* result, uint32_t result_len)
    private static final FunctionDescriptor COMPLETION_CALLBACK_DESC = FunctionDescriptor.ofVoid(
        ValueLayout.JAVA_LONG,          // uintptr_t completion_ctx
        ValueLayout.ADDRESS,            // tb_packet_t *packet
        ValueLayout.JAVA_LONG,          // uint64_t timestamp
        ValueLayout.ADDRESS,            // const uint8_t *result_ptr
        ValueLayout.JAVA_INT            // uint32_t result_len
    );

    private static final MethodHandle TB_CLIENT_INIT;
    private static final MethodHandle TB_CLIENT_SUBMIT;
    private static final MethodHandle TB_CLIENT_DEINIT;

    static {
        // Load the native library
        LIB = loadLibrary();

        TB_CLIENT_INIT = LINKER.downcallHandle(
            LIB.find("tb_client_init").orElseThrow(() ->
                new UnsatisfiedLinkError("tb_client_init not found")),
            TB_CLIENT_INIT_DESC
        );

        TB_CLIENT_SUBMIT = LINKER.downcallHandle(
            LIB.find("tb_client_submit").orElseThrow(() ->
                new UnsatisfiedLinkError("tb_client_submit not found")),
            TB_CLIENT_SUBMIT_DESC
        );

        TB_CLIENT_DEINIT = LINKER.downcallHandle(
            LIB.find("tb_client_deinit").orElseThrow(() ->
                new UnsatisfiedLinkError("tb_client_deinit not found")),
            TB_CLIENT_DEINIT_DESC
        );
    }

    private static SymbolLookup loadLibrary() {
        // Try to load from system path first, then from JAR resources
        String libName = System.mapLibraryName("tb_client");
        try {
            return SymbolLookup.libraryLookup(libName, Arena.global());
        } catch (IllegalArgumentException e) {
            // Fall back to extracting from JAR (similar to JNILoader logic)
            Path extractedLib = extractLibraryFromJar();
            if (extractedLib != null) {
                return SymbolLookup.libraryLookup(extractedLib, Arena.global());
            }
            throw new UnsatisfiedLinkError("Could not load tb_client library: " + e.getMessage());
        }
    }

    private static Path extractLibraryFromJar() {
        // TODO: Implement JAR extraction similar to JNILoader
        // For now, assume library is on system path
        return null;
    }

    // Instance fields
    private final Arena arena;
    private final MemorySegment clientHandle;
    private final MemorySegment callbackStub;
    private volatile boolean closed = false;

    /**
     * Creates a new PanamaClient connected to the specified cluster.
     *
     * @param clusterID 16-byte cluster identifier
     * @param addresses Comma-separated replica addresses
     * @throws InitializationException if initialization fails
     */
    public PanamaClient(byte[] clusterID, String addresses) throws InitializationException {
        if (clusterID.length != 16) {
            throw new IllegalArgumentException("ClusterID must be 16 bytes");
        }
        if (addresses == null || addresses.isEmpty()) {
            throw new IllegalArgumentException("Addresses cannot be null or empty");
        }

        this.arena = Arena.ofShared();

        try {
            // Allocate client handle
            this.clientHandle = arena.allocate(TB_CLIENT_SIZE, TB_CLIENT_ALIGNMENT);

            // Copy cluster ID to native memory
            MemorySegment clusterIdSegment = arena.allocate(16);
            clusterIdSegment.copyFrom(MemorySegment.ofArray(clusterID));

            // Copy addresses string to native memory
            MemorySegment addressesSegment = arena.allocateFrom(addresses);

            // Create upcall stub for completion callback
            MethodHandle callbackHandle;
            try {
                callbackHandle = MethodHandles.lookup().bind(this, "onCompletion",
                    MethodType.methodType(void.class,
                        long.class, MemorySegment.class, long.class, MemorySegment.class, int.class));
            } catch (NoSuchMethodException | IllegalAccessException e) {
                throw new RuntimeException("Failed to bind callback method", e);
            }

            this.callbackStub = LINKER.upcallStub(
                callbackHandle,
                COMPLETION_CALLBACK_DESC,
                arena
            );

            // Call tb_client_init
            int status;
            try {
                status = (int) TB_CLIENT_INIT.invokeExact(
                    clientHandle,
                    clusterIdSegment,
                    addressesSegment,
                    addresses.length(),
                    0L,  // completion_ctx - we use the callback stub's bound 'this'
                    callbackStub
                );
            } catch (Throwable t) {
                throw new RuntimeException("tb_client_init failed", t);
            }

            if (status != 0) {
                throw new InitializationException(status);
            }

        } catch (InitializationException e) {
            arena.close();
            throw e;
        } catch (Throwable t) {
            arena.close();
            throw new RuntimeException("Failed to initialize client", t);
        }
    }

    /**
     * Completion callback invoked from native code.
     * This method is called on a native thread.
     */
    @SuppressWarnings("unused") // Called via MethodHandle
    private void onCompletion(long ctx, MemorySegment packet, long timestamp,
                              MemorySegment resultPtr, int resultLen) {
        // TODO: Retrieve the Request from packet.user_data and invoke its callback
        // Similar logic to client.zig's on_completion function

        // For now, just log
        System.err.println("PanamaClient.onCompletion: timestamp=" + timestamp + ", resultLen=" + resultLen);
    }

    /**
     * Submits a request to the cluster.
     *
     * @param request The request to submit
     * @throws ClientClosedException if the client has been closed
     */
    public void submit(Request<?> request) throws ClientClosedException {
        if (closed) {
            throw new ClientClosedException();
        }

        // TODO: Implement packet allocation and submission
        // 1. Allocate tb_packet_t
        // 2. Set user_data to reference the Request (via a handle table)
        // 3. Set operation, data, data_size
        // 4. Call tb_client_submit

        throw new UnsupportedOperationException("submit() not yet implemented");
    }

    @Override
    public void close() {
        if (closed) {
            return;
        }
        closed = true;

        try {
            int status = (int) TB_CLIENT_DEINIT.invokeExact(clientHandle);
            if (status != 0) {
                // Log but don't throw - we're closing anyway
                System.err.println("tb_client_deinit returned status: " + status);
            }
        } catch (Throwable t) {
            System.err.println("Error during tb_client_deinit: " + t.getMessage());
        } finally {
            arena.close();
        }
    }
}
