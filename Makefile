TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = SpotifyFX

SpotifyFX_FILES = Tweak.m
SpotifyFX_CFLAGS = -fobjc-arc
SpotifyFX_FRAMEWORKS = Foundation UIKit AudioToolbox

include $(THEOS_MAKE_PATH)/library.mk
