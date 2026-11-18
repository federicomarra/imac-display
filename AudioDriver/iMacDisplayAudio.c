// iMacDisplay Audio: a Core Audio server plug-in that adds the connected iMac as an
// audio output of the Mac, like the speakers of an HDMI monitor.
//
// The device carries no audio itself: whatever apps play to it is discarded here and
// captured by the iMacDisplay app with a process tap on this device, then streamed.
// Volume and mute are plain controls; the app mirrors them to the iMac's system volume.
//
// The device exists only while the app is connected: the app sets the custom property
// kProperty_DeviceName on the plug-in object to the iMac's name to publish it, and to
// an empty string to remove it. If the app dies, the device is removed with it.
//
// Bump CFBundleVersion in Info.plist with every change: the app offers to reinstall
// the driver when the installed version differs from the bundled one.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#pragma mark - Constants

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream = 3,
    kObjectID_Volume = 4,
    kObjectID_Mute = 5,
};

#define kDeviceUID "com.federicomarra.imacdisplay.audio.device"
#define kModelUID "com.federicomarra.imacdisplay.audio.model"
#define kManufacturer "iMacDisplay"
#define kDefaultName "iMacDisplay"

/// Custom property on the plug-in object: CFString name of the device, empty = no device.
static const AudioObjectPropertySelector kProperty_DeviceName = 'imdN';

static const Float64 kSampleRate = 48000;
static const UInt32 kChannels = 2;
static const UInt32 kZeroTimeStampPeriod = 16384;
static const Float32 kMinDecibels = -64;

#pragma mark - State

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static atomic_uint gRefCount = 0;

static CFStringRef gDeviceName = NULL;   // NULL = device not published
static dispatch_source_t gOwnerWatch = NULL;
static Boolean gStreamActive = true;
static Float32 gVolume = 1;
static UInt32 gMute = 0;

static UInt32 gIOCount = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimeStampCount = 0;

static Boolean DevicePublished(void) {
    pthread_mutex_lock(&gMutex);
    Boolean published = gDeviceName != NULL;
    pthread_mutex_unlock(&gMutex);
    return published;
}

static Boolean IsDeviceObject(AudioObjectID objectID) {
    return objectID == kObjectID_Device || objectID == kObjectID_Stream ||
           objectID == kObjectID_Volume || objectID == kObjectID_Mute;
}

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kChannels * sizeof(Float32);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kChannels * sizeof(Float32);
    format.mChannelsPerFrame = kChannels;
    format.mBitsPerChannel = 32;
    return format;
}

static Float32 ScalarToDecibels(Float32 scalar) {
    if (scalar < 0) scalar = 0;
    if (scalar > 1) scalar = 1;
    return kMinDecibels * (1 - scalar);
}

static Float32 DecibelsToScalar(Float32 decibels) {
    if (decibels < kMinDecibels) decibels = kMinDecibels;
    if (decibels > 0) decibels = 0;
    return 1 - decibels / kMinDecibels;
}

static void NotifyChanged(AudioObjectID objectID, UInt32 count, const AudioObjectPropertyAddress* addresses) {
    if (gHost != NULL) gHost->PropertiesChanged(gHost, objectID, count, addresses);
}

static void NotifyDeviceListChanged(void) {
    const AudioObjectPropertyAddress addresses[] = {
        {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    NotifyChanged(kObjectID_PlugIn, 2, addresses);
}

/// Publishes the device under `name`, renames it, or removes it when `name` is empty.
/// `owner` is the process that asked; the device goes away when that process exits.
static void SetDeviceName(CFStringRef name, pid_t owner) {
    Boolean publish = name != NULL && CFStringGetLength(name) > 0;
    pthread_mutex_lock(&gMutex);
    Boolean wasPublished = gDeviceName != NULL;
    if (gDeviceName != NULL) CFRelease(gDeviceName);
    gDeviceName = publish ? CFStringCreateCopy(NULL, name) : NULL;
    if (gOwnerWatch != NULL) {
        dispatch_source_cancel(gOwnerWatch);
        dispatch_release(gOwnerWatch);
        gOwnerWatch = NULL;
    }
    if (publish && owner > 0) {
        gOwnerWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)owner, DISPATCH_PROC_EXIT,
                                             dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
        if (gOwnerWatch != NULL) {
            dispatch_source_set_event_handler(gOwnerWatch, ^{ SetDeviceName(NULL, 0); });
            dispatch_resume(gOwnerWatch);
        }
    }
    pthread_mutex_unlock(&gMutex);

    if (publish != wasPublished) {
        NotifyDeviceListChanged();
    } else if (publish) {
        const AudioObjectPropertyAddress address = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                                    kAudioObjectPropertyElementMain};
        NotifyChanged(kObjectID_Device, 1, &address);
    }
}

#pragma mark - IUnknown

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

static HRESULT QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface) {
    if (driver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void* driver) {
    return driver == gDriverRef ? atomic_fetch_add(&gRefCount, 1) + 1 : 0;
}

static ULONG Release(void* driver) {
    if (driver != gDriverRef) return 0;
    UInt32 count = atomic_load(&gRefCount);
    if (count == 0) return 0;
    return atomic_fetch_sub(&gRefCount, 1) - 1;
}

#pragma mark - Basic operations

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = host;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID device) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo* c) {
    return noErr;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo* c) {
    return noErr;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void* info) {
    return noErr;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void* info) {
    return noErr;
}

#pragma mark - Properties

static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t pid,
                           const AudioObjectPropertyAddress* address) {
    if (driver != gDriverRef || address == NULL) return false;
    if (IsDeviceObject(objectID) && !DevicePublished()) return false;
    AudioObjectPropertySelector s = address->mSelector;

    switch (objectID) {
    case kObjectID_PlugIn:
        return s == kAudioObjectPropertyBaseClass || s == kAudioObjectPropertyClass ||
               s == kAudioObjectPropertyOwner || s == kAudioObjectPropertyManufacturer ||
               s == kAudioObjectPropertyOwnedObjects || s == kAudioPlugInPropertyDeviceList ||
               s == kAudioPlugInPropertyTranslateUIDToDevice || s == kAudioPlugInPropertyResourceBundle ||
               s == kAudioObjectPropertyCustomPropertyInfoList || s == kProperty_DeviceName;
    case kObjectID_Device:
        return s == kAudioObjectPropertyBaseClass || s == kAudioObjectPropertyClass ||
               s == kAudioObjectPropertyOwner || s == kAudioObjectPropertyName ||
               s == kAudioObjectPropertyManufacturer || s == kAudioObjectPropertyOwnedObjects ||
               s == kAudioDevicePropertyDeviceUID || s == kAudioDevicePropertyModelUID ||
               s == kAudioDevicePropertyTransportType || s == kAudioDevicePropertyRelatedDevices ||
               s == kAudioDevicePropertyClockDomain || s == kAudioDevicePropertyDeviceIsAlive ||
               s == kAudioDevicePropertyDeviceIsRunning || s == kAudioDevicePropertyDeviceCanBeDefaultDevice ||
               s == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice || s == kAudioDevicePropertyLatency ||
               s == kAudioDevicePropertyStreams || s == kAudioObjectPropertyControlList ||
               s == kAudioDevicePropertySafetyOffset || s == kAudioDevicePropertyNominalSampleRate ||
               s == kAudioDevicePropertyAvailableNominalSampleRates || s == kAudioDevicePropertyIsHidden ||
               s == kAudioDevicePropertyPreferredChannelsForStereo ||
               s == kAudioDevicePropertyPreferredChannelLayout || s == kAudioDevicePropertyZeroTimeStampPeriod;
    case kObjectID_Stream:
        return s == kAudioObjectPropertyBaseClass || s == kAudioObjectPropertyClass ||
               s == kAudioObjectPropertyOwner || s == kAudioObjectPropertyOwnedObjects ||
               s == kAudioStreamPropertyIsActive || s == kAudioStreamPropertyDirection ||
               s == kAudioStreamPropertyTerminalType || s == kAudioStreamPropertyStartingChannel ||
               s == kAudioStreamPropertyLatency || s == kAudioStreamPropertyVirtualFormat ||
               s == kAudioStreamPropertyPhysicalFormat || s == kAudioStreamPropertyAvailableVirtualFormats ||
               s == kAudioStreamPropertyAvailablePhysicalFormats;
    case kObjectID_Volume:
        return s == kAudioObjectPropertyBaseClass || s == kAudioObjectPropertyClass ||
               s == kAudioObjectPropertyOwner || s == kAudioObjectPropertyOwnedObjects ||
               s == kAudioControlPropertyScope || s == kAudioControlPropertyElement ||
               s == kAudioLevelControlPropertyScalarValue || s == kAudioLevelControlPropertyDecibelValue ||
               s == kAudioLevelControlPropertyDecibelRange ||
               s == kAudioLevelControlPropertyConvertScalarToDecibels ||
               s == kAudioLevelControlPropertyConvertDecibelsToScalar;
    case kObjectID_Mute:
        return s == kAudioObjectPropertyBaseClass || s == kAudioObjectPropertyClass ||
               s == kAudioObjectPropertyOwner || s == kAudioObjectPropertyOwnedObjects ||
               s == kAudioControlPropertyScope || s == kAudioControlPropertyElement ||
               s == kAudioBooleanControlPropertyValue;
    }
    return false;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t pid,
                                   const AudioObjectPropertyAddress* address, Boolean* outSettable) {
    if (driver != gDriverRef || address == NULL || outSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(driver, objectID, pid, address)) return kAudioHardwareUnknownPropertyError;
    AudioObjectPropertySelector s = address->mSelector;
    *outSettable = (objectID == kObjectID_PlugIn && s == kProperty_DeviceName) ||
                   (objectID == kObjectID_Stream && (s == kAudioStreamPropertyIsActive ||
                                                     s == kAudioStreamPropertyVirtualFormat ||
                                                     s == kAudioStreamPropertyPhysicalFormat)) ||
                   (objectID == kObjectID_Volume && (s == kAudioLevelControlPropertyScalarValue ||
                                                     s == kAudioLevelControlPropertyDecibelValue)) ||
                   (objectID == kObjectID_Mute && s == kAudioBooleanControlPropertyValue);
    return noErr;
}

/// Writes one value of type T into outData, checking the caller's buffer size.
#define RETURN_VALUE(T, value)                                          \
    do {                                                                \
        if (inDataSize < sizeof(T)) return kAudioHardwareBadPropertySizeError; \
        *(T*)outData = (value);                                         \
        *outDataSize = sizeof(T);                                       \
        return noErr;                                                   \
    } while (0)

/// Copies up to `count` object IDs into outData.
static OSStatus ReturnObjectList(const AudioObjectID* ids, UInt32 count, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    UInt32 fit = inDataSize / sizeof(AudioObjectID);
    if (fit > count) fit = count;
    memcpy(outData, ids, fit * sizeof(AudioObjectID));
    *outDataSize = fit * sizeof(AudioObjectID);
    return noErr;
}

/// Object lists, filtered by scope where it matters (the device has output objects only).
static UInt32 OwnedObjects(AudioObjectID objectID, AudioObjectPropertyScope scope, AudioObjectID* out) {
    switch (objectID) {
    case kObjectID_PlugIn:
        if (!DevicePublished()) return 0;
        out[0] = kObjectID_Device;
        return 1;
    case kObjectID_Device:
        if (scope == kAudioObjectPropertyScopeInput) return 0;
        out[0] = kObjectID_Stream;
        out[1] = kObjectID_Volume;
        out[2] = kObjectID_Mute;
        return 3;
    }
    return 0;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t pid,
                                    const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                                    const void* qualifier, UInt32* outDataSize) {
    if (driver != gDriverRef || address == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(driver, objectID, pid, address)) return kAudioHardwareUnknownPropertyError;
    AudioObjectPropertySelector s = address->mSelector;
    AudioObjectID ids[3];

    switch (s) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:  // kAudioStreamPropertyLatency == kAudioDevicePropertyLatency
    case kAudioControlPropertyScope:
    case kAudioControlPropertyElement:
    case kAudioBooleanControlPropertyValue:
        *outDataSize = sizeof(UInt32);
        return noErr;
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioPlugInPropertyResourceBundle:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kProperty_DeviceName:
        *outDataSize = sizeof(CFStringRef);
        return noErr;
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
        *outDataSize = OwnedObjects(objectID, address->mScope, ids) * sizeof(AudioObjectID);
        return noErr;
    case kAudioDevicePropertyRelatedDevices:
        *outDataSize = sizeof(AudioObjectID);
        return noErr;
    case kAudioDevicePropertyStreams:
        *outDataSize = address->mScope == kAudioObjectPropertyScopeInput ? 0 : sizeof(AudioObjectID);
        return noErr;
    case kAudioObjectPropertyControlList:
        *outDataSize = 2 * sizeof(AudioObjectID);
        return noErr;
    case kAudioDevicePropertyNominalSampleRate:
        *outDataSize = sizeof(Float64);
        return noErr;
    case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioLevelControlPropertyDecibelRange:
        *outDataSize = sizeof(AudioValueRange);
        return noErr;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        *outDataSize = 2 * sizeof(UInt32);
        return noErr;
    case kAudioDevicePropertyPreferredChannelLayout:
        *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription);
        return noErr;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        *outDataSize = sizeof(AudioStreamBasicDescription);
        return noErr;
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        *outDataSize = sizeof(AudioStreamRangedDescription);
        return noErr;
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue:
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        *outDataSize = sizeof(Float32);
        return noErr;
    case kAudioObjectPropertyCustomPropertyInfoList:
        *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
        return noErr;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t pid,
                                const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                                const void* qualifier, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (driver != gDriverRef || address == NULL || outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!HasProperty(driver, objectID, pid, address)) return kAudioHardwareUnknownPropertyError;
    AudioObjectPropertySelector s = address->mSelector;
    AudioObjectID ids[3];

    // Properties shared by several objects.
    switch (s) {
    case kAudioObjectPropertyBaseClass:
        switch (objectID) {
        case kObjectID_Volume: RETURN_VALUE(AudioClassID, kAudioLevelControlClassID);
        case kObjectID_Mute: RETURN_VALUE(AudioClassID, kAudioBooleanControlClassID);
        default: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        }
    case kAudioObjectPropertyClass:
        switch (objectID) {
        case kObjectID_PlugIn: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kObjectID_Device: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kObjectID_Stream: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kObjectID_Volume: RETURN_VALUE(AudioClassID, kAudioVolumeControlClassID);
        default: RETURN_VALUE(AudioClassID, kAudioMuteControlClassID);
        }
    case kAudioObjectPropertyOwner:
        RETURN_VALUE(AudioObjectID, objectID == kObjectID_PlugIn ? kAudioObjectUnknown
                                    : objectID == kObjectID_Device ? kObjectID_PlugIn : kObjectID_Device);
    case kAudioObjectPropertyManufacturer:
        RETURN_VALUE(CFStringRef, CFSTR(kManufacturer));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
        return ReturnObjectList(ids, OwnedObjects(objectID, address->mScope, ids), inDataSize, outDataSize, outData);
    case kAudioControlPropertyScope:
        RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement:
        RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    }

    // Plug-in.
    if (objectID == kObjectID_PlugIn) {
        switch (s) {
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qualifierSize < sizeof(CFStringRef) || qualifier == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef*)qualifier;
            Boolean match = DevicePublished() && uid != NULL && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo;
            RETURN_VALUE(AudioObjectID, match ? kObjectID_Device : kAudioObjectUnknown);
        }
        case kAudioPlugInPropertyResourceBundle:
            RETURN_VALUE(CFStringRef, CFSTR(""));
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo info = {kProperty_DeviceName,
                                                        kAudioServerPlugInCustomPropertyDataTypeCFString,
                                                        kAudioServerPlugInCustomPropertyDataTypeNone};
            RETURN_VALUE(AudioServerPlugInCustomPropertyInfo, info);
        }
        case kProperty_DeviceName: {
            pthread_mutex_lock(&gMutex);
            CFStringRef name = gDeviceName != NULL ? CFStringCreateCopy(NULL, gDeviceName) : CFSTR("");
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(CFStringRef, name);
        }
        }
    }

    // Device.
    if (objectID == kObjectID_Device) {
        switch (s) {
        case kAudioObjectPropertyName: {
            pthread_mutex_lock(&gMutex);
            CFStringRef name = gDeviceName != NULL ? CFStringCreateCopy(NULL, gDeviceName) : CFSTR(kDefaultName);
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(CFStringRef, name);
        }
        case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID: RETURN_VALUE(CFStringRef, CFSTR(kModelUID));
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gMutex);
            UInt32 running = gIOCount > 0;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            RETURN_VALUE(UInt32, address->mScope != kAudioObjectPropertyScopeInput);
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
            RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kZeroTimeStampPeriod);
        case kAudioDevicePropertyStreams:
            if (address->mScope == kAudioObjectPropertyScopeInput) {
                *outDataSize = 0;
                return noErr;
            }
            RETURN_VALUE(AudioObjectID, kObjectID_Stream);
        case kAudioObjectPropertyControlList: {
            const AudioObjectID controls[] = {kObjectID_Volume, kObjectID_Mute};
            return ReturnObjectList(controls, 2, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = {kSampleRate, kSampleRate};
            RETURN_VALUE(AudioValueRange, range);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription);
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* layout = outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannels;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = size;
            return noErr;
        }
        }
    }

    // Stream.
    if (objectID == kObjectID_Stream) {
        switch (s) {
        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gMutex);
            UInt32 active = gStreamActive;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(UInt32, active);
        }
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, 0);  // 0 = output
        case kAudioStreamPropertyTerminalType: RETURN_VALUE(UInt32, kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            RETURN_VALUE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription ranged = {StreamFormat(), {kSampleRate, kSampleRate}};
            RETURN_VALUE(AudioStreamRangedDescription, ranged);
        }
        }
    }

    // Volume.
    if (objectID == kObjectID_Volume) {
        switch (s) {
        case kAudioLevelControlPropertyScalarValue: {
            pthread_mutex_lock(&gMutex);
            Float32 volume = gVolume;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(Float32, volume);
        }
        case kAudioLevelControlPropertyDecibelValue: {
            pthread_mutex_lock(&gMutex);
            Float32 volume = gVolume;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(Float32, ScalarToDecibels(volume));
        }
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange range = {kMinDecibels, 0};
            RETURN_VALUE(AudioValueRange, range);
        }
        // Translations: outData holds the input value on entry.
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            *(Float32*)outData = ScalarToDecibels(*(Float32*)outData);
            *outDataSize = sizeof(Float32);
            return noErr;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            *(Float32*)outData = DecibelsToScalar(*(Float32*)outData);
            *outDataSize = sizeof(Float32);
            return noErr;
        }
    }

    // Mute.
    if (objectID == kObjectID_Mute && s == kAudioBooleanControlPropertyValue) {
        pthread_mutex_lock(&gMutex);
        UInt32 mute = gMute;
        pthread_mutex_unlock(&gMutex);
        RETURN_VALUE(UInt32, mute);
    }

    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t pid,
                                const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                                const void* qualifier, UInt32 inDataSize, const void* inData) {
    if (driver != gDriverRef || address == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    Boolean settable = false;
    OSStatus status = IsPropertySettable(driver, objectID, pid, address, &settable);
    if (status != noErr) return status;
    if (!settable) return kAudioHardwareUnsupportedOperationError;
    AudioObjectPropertySelector s = address->mSelector;

    if (objectID == kObjectID_PlugIn && s == kProperty_DeviceName) {
        if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        SetDeviceName(*(const CFStringRef*)inData, pid);
        return noErr;
    }

    if (objectID == kObjectID_Stream) {
        if (s == kAudioStreamPropertyIsActive) {
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gMutex);
            gStreamActive = *(const UInt32*)inData != 0;
            pthread_mutex_unlock(&gMutex);
            const AudioObjectPropertyAddress changed = {kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal,
                                                        kAudioObjectPropertyElementMain};
            NotifyChanged(kObjectID_Stream, 1, &changed);
            return noErr;
        }
        // Only the one supported format can be "set".
        if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* format = inData;
        AudioStreamBasicDescription supported = StreamFormat();
        if (format->mSampleRate != supported.mSampleRate || format->mFormatID != supported.mFormatID ||
            format->mChannelsPerFrame != supported.mChannelsPerFrame ||
            format->mBitsPerChannel != supported.mBitsPerChannel) {
            return kAudioDeviceUnsupportedFormatError;
        }
        return noErr;
    }

    if (objectID == kObjectID_Volume) {
        if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value = *(const Float32*)inData;
        Float32 scalar = s == kAudioLevelControlPropertyScalarValue ? value : DecibelsToScalar(value);
        if (scalar < 0) scalar = 0;
        if (scalar > 1) scalar = 1;
        pthread_mutex_lock(&gMutex);
        Boolean changed = gVolume != scalar;
        gVolume = scalar;
        pthread_mutex_unlock(&gMutex);
        if (changed) {
            const AudioObjectPropertyAddress addresses[] = {
                {kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
                {kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            };
            NotifyChanged(kObjectID_Volume, 2, addresses);
        }
        return noErr;
    }

    if (objectID == kObjectID_Mute) {
        if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        UInt32 mute = *(const UInt32*)inData != 0;
        pthread_mutex_lock(&gMutex);
        Boolean changed = gMute != mute;
        gMute = mute;
        pthread_mutex_unlock(&gMutex);
        if (changed) {
            const AudioObjectPropertyAddress address = {kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
                                                        kAudioObjectPropertyElementMain};
            NotifyChanged(kObjectID_Mute, 1, &address);
        }
        return noErr;
    }

    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - IO

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    if (driver != gDriverRef || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount == 0) {
        gTimeStampCount = 0;
        gAnchorHostTime = mach_absolute_time();
    }
    gIOCount++;
    pthread_mutex_unlock(&gMutex);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    if (driver != gDriverRef || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gMutex);
    return noErr;
}

/// The device clock runs on the host clock: one zero time stamp every kZeroTimeStampPeriod frames.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                                 Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    if (driver != gDriverRef || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    Float64 ticksPerPeriod = gHostTicksPerFrame * kZeroTimeStampPeriod;
    UInt64 next = gAnchorHostTime + (UInt64)((gTimeStampCount + 1) * ticksPerPeriod);
    if (next <= mach_absolute_time()) gTimeStampCount++;
    *outSampleTime = (Float64)gTimeStampCount * kZeroTimeStampPeriod;
    *outHostTime = gAnchorHostTime + (UInt64)(gTimeStampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gMutex);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                                  UInt32 operation, Boolean* outWillDo, Boolean* outInPlace) {
    *outWillDo = operation == kAudioServerPlugInIOOperationWriteMix;
    *outInPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo* info) {
    return noErr;
}

/// The mixed output is dropped: the app captures it with a process tap on this device.
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, AudioObjectID stream, UInt32 client,
                              UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo* info,
                              void* mainBuffer, void* secondaryBuffer) {
    return noErr;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation,
                               UInt32 frames, const AudioServerPlugInIOCycleInfo* info) {
    return noErr;
}

#pragma mark - Factory

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};

/// Entry point named in Info.plist (CFPlugInFactories).
void* iMacDisplayAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    atomic_fetch_add(&gRefCount, 1);
    return gDriverRef;
}
