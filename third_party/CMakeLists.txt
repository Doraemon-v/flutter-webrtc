include(ExternalProject)

get_filename_component(THIRD_PARTY_REAL_DIR "${CMAKE_CURRENT_LIST_DIR}" REALPATH)
set(DOWNLOAD_DIR "${THIRD_PARTY_REAL_DIR}/downloads")
set(LIBWEBRTC_DIR "${THIRD_PARTY_REAL_DIR}/libwebrtc")
set(ZIPFILE "${DOWNLOAD_DIR}/libwebrtc.zip")
set(DEFAULT_DOWNLOAD_URL "https://github.com/flutter-webrtc/flutter-webrtc/releases/download/v1.4.0/libwebrtc.zip")
set(DOWNLOAD_URL "$ENV{FLUTTER_WEBRTC_DOWNLOAD_URL}")
set(LOCAL_ZIP_OVERRIDE "$ENV{FLUTTER_WEBRTC_LIBWEBRTC_ZIP}")

if(DOWNLOAD_URL STREQUAL "")
  set(DOWNLOAD_URL "${DEFAULT_DOWNLOAD_URL}")
endif()

file(MAKE_DIRECTORY "${DOWNLOAD_DIR}")

if(NOT LOCAL_ZIP_OVERRIDE STREQUAL "")
  if(EXISTS "${LOCAL_ZIP_OVERRIDE}")
    message(NOTICE "use local libwebrtc archive: ${LOCAL_ZIP_OVERRIDE}")
    file(COPY_FILE "${LOCAL_ZIP_OVERRIDE}" "${ZIPFILE}" ONLY_IF_DIFFERENT)
  else()
    message(FATAL_ERROR "FLUTTER_WEBRTC_LIBWEBRTC_ZIP is set but file does not exist: ${LOCAL_ZIP_OVERRIDE}")
  endif()
endif()

if(NOT EXISTS "${ZIPFILE}")
  message(NOTICE "download: ${DOWNLOAD_URL}")
  file(DOWNLOAD "${DOWNLOAD_URL}"
      "${ZIPFILE}"
      STATUS download_status
      TIMEOUT 600
      INACTIVITY_TIMEOUT 60
      LOG download_log)

  list(GET download_status 0 download_status_code)
  if(NOT download_status_code EQUAL 0)
    message(FATAL_ERROR "Failed to download dependency: ${download_log}")
  endif()

  file(ARCHIVE_EXTRACT INPUT "${ZIPFILE}" DESTINATION "${THIRD_PARTY_REAL_DIR}")
else()
  if(NOT EXISTS "${LIBWEBRTC_DIR}")
    message(NOTICE "libwebrtc directory does not exist after extraction.")
    file(ARCHIVE_EXTRACT INPUT "${ZIPFILE}" DESTINATION "${THIRD_PARTY_REAL_DIR}")
  endif()
  message(TRACE "libwebrtc already downloaded.")
endif()

