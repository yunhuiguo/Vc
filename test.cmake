if(NOT CTEST_SOURCE_DIRECTORY)
   get_filename_component(CTEST_SOURCE_DIRECTORY "${CMAKE_CURRENT_LIST_FILE}" PATH)
endif()

set(dashboard_model "$ENV{dashboard_model}")
set(target_architecture "$ENV{target_architecture}")
set(skip_tests "$ENV{skip_tests}")

execute_process(COMMAND uname -s OUTPUT_VARIABLE arch OUTPUT_STRIP_TRAILING_WHITESPACE)
string(TOLOWER "${arch}" arch)
execute_process(COMMAND uname -m OUTPUT_VARIABLE chip OUTPUT_STRIP_TRAILING_WHITESPACE)
string(TOLOWER "${chip}" chip)
if(arch MATCHES "mingw")
   execute_process(COMMAND cl COMMAND awk "/Version/ { print $8 }" OUTPUT_STRIP_TRAILING_WHITESPACE OUTPUT_VARIABLE COMPILER_VERSION)
   set(COMPILER_VERSION "MSVC ${COMPILER_VERSION}")
   execute_process(COMMAND reg query "HKLM\\HARDWARE\\DESCRIPTION\\System\\CentralProcessor" COMMAND grep -c CentralProcessor OUTPUT_STRIP_TRAILING_WHITESPACE OUTPUT_VARIABLE number_of_processors)
else()
   set(_cxx "$ENV{CXX}")
   if(NOT _cxx)
      set(_cxx "c++")
   endif()
   execute_process(COMMAND ${_cxx} --version COMMAND head -n1 OUTPUT_VARIABLE COMPILER_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
   if(arch STREQUAL "darwin")
      execute_process(COMMAND sysctl -n hw.ncpu OUTPUT_STRIP_TRAILING_WHITESPACE OUTPUT_VARIABLE number_of_processors)
   else()
      execute_process(COMMAND grep -c processor /proc/cpuinfo OUTPUT_STRIP_TRAILING_WHITESPACE OUTPUT_VARIABLE number_of_processors)
   endif()
endif()

if(arch STREQUAL "linux")
   execute_process(COMMAND lsb_release -d COMMAND cut -f2 OUTPUT_STRIP_TRAILING_WHITESPACE OUTPUT_VARIABLE arch)
endif()
set(CTEST_BUILD_NAME "${arch} ${chip} ${COMPILER_VERSION} $ENV{CXXFLAGS} ${target_architecture}")
string(STRIP "${CTEST_BUILD_NAME}" CTEST_BUILD_NAME)
string(REPLACE "/" "_" CTEST_BUILD_NAME "${CTEST_BUILD_NAME}")
string(REPLACE "+" "x" CTEST_BUILD_NAME "${CTEST_BUILD_NAME}") # CDash fails to escape '+' correctly in URIs
string(REGEX REPLACE "[][ ()]" "_" CTEST_BINARY_DIRECTORY "${CTEST_BUILD_NAME}")
set(CTEST_BINARY_DIRECTORY "${CTEST_SOURCE_DIRECTORY}/build-${dashboard_model}-${CTEST_BINARY_DIRECTORY}")
file(MAKE_DIRECTORY "${CTEST_BINARY_DIRECTORY}")

execute_process(COMMAND hostname -s RESULT_VARIABLE ok OUTPUT_VARIABLE CTEST_SITE ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT ok EQUAL 0)
   execute_process(COMMAND hostname OUTPUT_VARIABLE CTEST_SITE ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE)
endif()

Set(CTEST_START_WITH_EMPTY_BINARY_DIRECTORY_ONCE TRUE)

file(READ "${CTEST_SOURCE_DIRECTORY}/.git/HEAD" git_branch)
string(STRIP "${git_branch}" git_branch)
# -> ref: refs/heads/master
string(REGEX REPLACE "^.*/" "" git_branch "${git_branch}")
# -> master
set(CTEST_NOTES_FILES "${CTEST_SOURCE_DIRECTORY}/.git/HEAD" "${CTEST_SOURCE_DIRECTORY}/.git/refs/heads/${git_branch}")

include(CTestCustom.cmake)
include(CTestConfig.cmake)
set(CTEST_USE_LAUNCHERS 1) # much improved error/warning message logging
set(MAKE_ARGS "-j${number_of_processors} -i")

message("********************************")
#message("src:        ${CTEST_SOURCE_DIRECTORY}")
#message("obj:        ${CTEST_BINARY_DIRECTORY}")
message("build name: ${CTEST_BUILD_NAME}")
message("site:       ${CTEST_SITE}")
message("model:      ${dashboard_model}")
message("********************************")

if(WIN32)
   find_program(JOM jom)
   if(JOM)
      set(CTEST_CMAKE_GENERATOR "NMake Makefiles JOM")
      set(CMAKE_MAKE_PROGRAM "jom")
   else()
      set(CTEST_CMAKE_GENERATOR "NMake Makefiles")
      set(CMAKE_MAKE_PROGRAM "nmake")
      set(MAKE_ARGS "-I")
   endif()
else()
   set(CTEST_CMAKE_GENERATOR "Unix Makefiles")
   set(CMAKE_MAKE_PROGRAM "make")
endif()

set(configure_options "-DCTEST_USE_LAUNCHERS=${CTEST_USE_LAUNCHERS};-DCMAKE_BUILD_TYPE=Release;-DBUILD_EXAMPLES=TRUE")
if(target_architecture)
   set(configure_options "${configure_options};-DTARGET_ARCHITECTURE=${target_architecture}")
endif()

macro(go)
   CTEST_START (${dashboard_model})
   set(res 0)
   if(NOT ${dashboard_model} STREQUAL "Experimental")
      CTEST_UPDATE (SOURCE "${CTEST_SOURCE_DIRECTORY}" RETURN_VALUE res)
      if(res GREATER 0)
         ctest_submit(PARTS Update)
      endif()
   endif()
   if(NOT ${dashboard_model} STREQUAL "Continuous" OR res GREATER 0)
      CTEST_CONFIGURE (BUILD "${CTEST_BINARY_DIRECTORY}"
         OPTIONS "${configure_options}"
         APPEND
         RETURN_VALUE res)
      ctest_submit(PARTS Notes Configure)
      if(res EQUAL 0)
         foreach(subproject ${CTEST_PROJECT_SUBPROJECTS})
            set_property(GLOBAL PROPERTY SubProject ${subproject})
            set_property(GLOBAL PROPERTY Label ${subproject})
            set(CTEST_BUILD_TARGET "${subproject}")
            set(CTEST_BUILD_COMMAND "${CMAKE_MAKE_PROGRAM} ${MAKE_ARGS} ${CTEST_BUILD_TARGET}")
            ctest_build(
               BUILD "${CTEST_BINARY_DIRECTORY}"
               APPEND
               RETURN_VALUE res)
            ctest_submit(PARTS Build)
            if(res EQUAL 0 AND NOT skip_tests)
               ctest_test(
                  BUILD "${CTEST_BINARY_DIRECTORY}"
                  APPEND
                  RETURN_VALUE res
                  PARALLEL_LEVEL ${number_of_processors}
                  INCLUDE_LABEL "${subproject}")
               ctest_submit(PARTS Test)
            endif()
         endforeach()
      endif()
   endif()
endmacro()

if(${dashboard_model} STREQUAL "Continuous")
   while(${CTEST_ELAPSED_TIME} LESS 64800)
      set(START_TIME ${CTEST_ELAPSED_TIME})
      go()
      ctest_sleep(${START_TIME} 1200 ${CTEST_ELAPSED_TIME})
   endwhile()
else()
   CTEST_EMPTY_BINARY_DIRECTORY(${CTEST_BINARY_DIRECTORY})
   go()
endif()
