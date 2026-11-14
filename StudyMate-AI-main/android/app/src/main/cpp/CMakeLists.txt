cmake_minimum_required(VERSION 3.22)
project(studymate_llm CXX C)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp llama_build)

add_library(studymate_llm SHARED studymate_llm.cpp)
target_include_directories(studymate_llm PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/include)
target_link_libraries(studymate_llm llama log)
