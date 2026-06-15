include(ExternalProject)

get_filename_component(THIRD_PARTY_REAL_DIR "${CMAKE_CURRENT_LIST_DIR}" REALPATH)
set(DOWNLOAD_DIR "${THIRD_PARTY_REAL_DIR}/downloads")
set(LIBWEBRTC_DIR "${THIRD_PARTY_REAL_DIR}/libwebrtc")
set(ZIPFILE "${DOWNLOAD_DIR}/libwebrtc.zip")
set(DOWNLOAD_URL "https://github.com/flutter-webrtc/flutter-webrtc/releases/download/v1.4.0/libwebrtc.zip")

file(MAKE_DIRECTORY "${DOWNLOAD_DIR}")

if(NOT EXISTS "${ZIPFILE}")
  message(NOTICE "download: ${DOWNLOAD_URL}")
  file(DOWNLOAD "${DOWNLOAD_URL}"
      "${ZIPFILE}"
      STATUS download_status
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

