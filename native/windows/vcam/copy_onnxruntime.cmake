# Copies the ONNX Runtime DLLs next to the receiver when they have been fetched.
if(EXISTS "${SRC}/onnxruntime.dll")
    file(COPY "${SRC}/onnxruntime.dll" "${SRC}/onnxruntime_providers_shared.dll" DESTINATION "${DST}")
endif()
