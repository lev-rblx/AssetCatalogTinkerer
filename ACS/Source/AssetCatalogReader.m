//
//  AssetCatalogReader.m
//  Asset Catalog Tinkerer
//
//  Created by Guilherme Rambo on 27/03/16.
//  Copyright © 2016 Guilherme Rambo. All rights reserved.
//

#import "AssetCatalogReader.h"

#import "CoreUI.h"
#import "CoreUI+TV.h"

NSString * const kACSNameKey = @"name";
NSString * const kACSImageKey = @"image";
NSString * const kACSThumbnailKey = @"thumbnail";
NSString * const kACSFilenameKey = @"filename";
NSString * const kACSCompressedSizeKey = @"compressedSize";
NSString * const kACSUncompressedSizeKey = @"uncompressedSize";
NSString * const kACSContentsDataKey = @"data";
NSString * const kACSImageRepKey = @"imagerep";

NSString * const kAssetCatalogReaderErrorDomain = @"br.com.guilhermerambo.AssetCatalogReader";

@interface AssetCatalogReader ()

@property (nonatomic, copy) NSURL *fileURL;
@property (nonatomic, strong) CUICatalog *catalog;
@property (nonatomic, strong) NSMutableArray <NSDictionary <NSString *, NSObject *> *> *mutableImages;

@property (assign) NSUInteger totalNumberOfAssets;

// These properties are set when the read is initiated by a call to `resourceConstrainedReadWithMaxCount`
@property (nonatomic, assign, getter=isResourceConstrained) BOOL resourceConstrained;
@property (nonatomic, assign) int maxCount;

@end

@implementation AssetCatalogReader
{
    BOOL _computedCatalogHasRetinaContent;
    BOOL _catalogHasRetinaContent;
}

- (instancetype)initWithFileURL:(NSURL *)URL
{
    self = [super init];
    
    _ignorePackedAssets = YES;
    _fileURL = [URL copy];
    
    return self;
}

- (NSMutableArray <NSDictionary <NSString *, NSObject *> *> *)mutableImages
{
    if (!_mutableImages) _mutableImages = [NSMutableArray new];
    
    return _mutableImages;
}

- (NSArray <NSDictionary <NSString *, NSObject *> *> *)images
{
    return [self.mutableImages copy];
}

- (void)cancelReading
{
    self.cancelled = true;
}

- (void)resourceConstrainedReadWithMaxCount:(int)max completionHandler:(void (^)(void))callback
{
    self.resourceConstrained = YES;
    self.maxCount = max;
    
    [self readWithCompletionHandler:callback progressHandler:nil];
}

- (void)readWithCompletionHandler:(void (^__nonnull)(void))callback progressHandler:(void (^__nullable)(double progress))progressCallback
{
    __block uint64 totalItemCount = 0;
    __block uint64 loadedItemCount = 0;
    __block uint64 maxItemCount = _maxCount;
    
    NSString *catalogPath = self.fileURL.path;
    
    if (!_resourceConstrained) {
        // we need to figure out if the user selected an app bundle or a specific .car file
        NSBundle *bundle = [NSBundle bundleWithURL:self.fileURL];
        if (!bundle) {
            catalogPath = self.fileURL.path;
            self.catalogName = catalogPath.lastPathComponent;
        } else {
            catalogPath = [bundle pathForResource:@"Assets" ofType:@"car"];
            self.catalogName = [NSString stringWithFormat:@"%@ | %@", bundle.bundlePath.lastPathComponent, catalogPath.lastPathComponent];
        }
    }

    __weak typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // bundle is nil for some reason
        if (!catalogPath) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.error = [NSError errorWithDomain:kAssetCatalogReaderErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"Unable to find asset catalog path"}];
                callback();
            });
            
            return;
        }
        
        NSError *catalogError;
        self.catalog = [[CUICatalog alloc] initWithURL:[NSURL fileURLWithPath:catalogPath] error:&catalogError];
        if (catalogError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.error = catalogError;
                callback();
            });
            
            return;
        }
        
        if ([self isProThemeStoreAtPath:catalogPath]) {
            NSError *error = [NSError errorWithDomain:kAssetCatalogReaderErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"Pro asset catalogs are not supported"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.error = error;
                callback();
            });
            
            return;
        }
        
        if (self.distinguishCatalogsFromThemeStores) {
            if (!self.catalog.allImageNames.count || ![self.catalog respondsToSelector:@selector(imageWithName:scaleFactor:)]) {
                // CAR is a theme file not an asset catalog
                return [self readThemeStoreWithCompletionHandler:callback progressHandler:progressCallback];
            }
        } else {
            return [self readThemeStoreWithCompletionHandler:callback progressHandler:progressCallback];
        }
        
        weakSelf.totalNumberOfAssets = self.catalog.allImageNames.count;
        
        // limits the total items to be read to the total number of images or the max count set for a resource constrained read
        totalItemCount = weakSelf.resourceConstrained ? MIN(maxItemCount, weakSelf.catalog.allImageNames.count) : weakSelf.catalog.allImageNames.count;
        
        for (NSString *imageName in self.catalog.allImageNames) {
            if (weakSelf.resourceConstrained && loadedItemCount >= totalItemCount) break;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                double loadedFraction = (double)loadedItemCount / (double)totalItemCount;
                if (progressCallback) progressCallback(loadedFraction);
            });
            
            for (CUINamedImage *namedImage in [self imagesNamed:imageName]) {
                if (self.cancelled) return;
                
                @autoreleasepool {
                    if (namedImage == nil) {
                        loadedItemCount++;
                        continue;
                    }

                    if ([namedImage isKindOfClass:[CUINamedData class]]) {
                        loadedItemCount++;
                        continue;
                    }

                    NSString *filename;
                    CGImageRef image;
                    NSUInteger dataLength = 0;

                    if ([namedImage isKindOfClass:[CUINamedLayerStack class]]) {
                        CUINamedLayerStack *stack = (CUINamedLayerStack *)namedImage;
                        if (!stack.layers.count) {
                            loadedItemCount++;
                            continue;
                        }
                        
                        filename = [NSString stringWithFormat:@"%@.png", namedImage.name];
                        image = stack.flattenedImage;
                    } else {
                        filename = [self filenameForAssetNamed:namedImage.name scale:namedImage.scale presentationState:kCoreThemeStateNone];
                        image = namedImage.image;
                    }
                    
                    if (image == nil) {
                        loadedItemCount++;
                        continue;
                    }
                    
                    // when resource constrained and the catalog contains retina images, only load retina images
                    if ([self catalogHasRetinaContent] && weakSelf.resourceConstrained && namedImage.scale < 2) {
                        continue;
                    }

                    NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCGImage:image];
                    imageRep.size = namedImage.size;

                    NSDictionary *desc = [self imageDescriptionWithName:namedImage.name filename:filename representation:imageRep dataLength:dataLength contentsData:^NSData *{
                        return [imageRep representationUsingType:NSBitmapImageFileTypePNG properties:@{NSImageInterlaced:@(NO)}];
                    }];

                    if (!desc) {
                        loadedItemCount++;
                        return;
                    }
                    
                    if (self.cancelled) return;
                    
                    [self.mutableImages addObject:desc];
                    
                    if (self.cancelled) return;
                    
                    loadedItemCount++;
                }
            }
        }
        
        // we've got no images for some reason (the console will usually contain some information from CoreUI as to why)
        if (!self.images.count) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.error = [NSError errorWithDomain:kAssetCatalogReaderErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"Failed to load images"}];
                callback();
            });
            
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            callback();
        });
    });
}

- (void)readThemeStoreWithCompletionHandler:(void (^__nonnull)(void))callback progressHandler:(void (^__nullable)(double progress))progressCallback
{
    uint64 realTotalItemCount = [self.catalog _themeStore].themeStore.allAssetKeys.count;
    __block uint64 loadedItemCount = 0;
    
    // limits the total items to be read to the total number of images or the max count set for a resource constrained read
    __block uint64 totalItemCount = self.resourceConstrained ? MIN(_maxCount, realTotalItemCount) : realTotalItemCount;
    
    _totalNumberOfAssets = [self.catalog _themeStore].themeStore.allAssetKeys.count;

    __weak typeof(self) weakSelf = self;

    [[self.catalog _themeStore].themeStore.allAssetKeys enumerateObjectsWithOptions:0 usingBlock:^(CUIRenditionKey * _Nonnull key, NSUInteger idx, BOOL * _Nonnull stop) {
        if (weakSelf.resourceConstrained && loadedItemCount >= totalItemCount) return;
        
        if (self.cancelled) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            double loadedFraction = (double)loadedItemCount / (double)totalItemCount;
            if (progressCallback) progressCallback(loadedFraction);
        });
        
        @try {
            CUIThemeRendition *rendition = [[self.catalog _themeStore] renditionWithKey:key.keyList];
            // when resource constrained and the catalog contains retina images, only load retina images
            if ([self catalogHasRetinaContent] && weakSelf.resourceConstrained && rendition.scale < 2) {
                return;
            }
            
            const BOOL coreSVGPresent = CGSVGDocumentGetCanvasSize != NULL && CGContextDrawSVGDocument != NULL && CGSVGDocumentWriteToData != NULL;
            const BOOL isSVG = coreSVGPresent && rendition.isVectorBased && rendition.svgDocument;

            if (isSVG) {
                NSCustomImageRep *imageRep = [[NSCustomImageRep alloc] initWithSize:CGSVGDocumentGetCanvasSize(rendition.svgDocument) flipped:YES drawingHandler:^BOOL(NSRect dstRect) {
                    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
                    if (context && rendition.svgDocument) {
                        CGContextDrawSVGDocument(context, rendition.svgDocument);
                    }
                    return YES;
                }];
                NSString *const filename = [self filenameForVectorAssetNamed:[self cleanupRenditionName:rendition.name] renderingMode:rendition.vectorGlyphRenderingMode weight:key.themeGlyphWeight size:key.themeGlyphSize];
                NSDictionary *desc = [self imageDescriptionWithName:rendition.name filename:filename representation:imageRep dataLength:rendition.srcData.length contentsData:^NSData *{
                    NSMutableData *data = [NSMutableData new];
                    CGSVGDocumentWriteToData(rendition.svgDocument, (__bridge CFMutableDataRef)data, NULL);
                    return data;
                }];
                if (self.cancelled) return;
                [self.mutableImages addObject:desc];
            } else if (rendition.unslicedImage) {
                NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithCGImage:rendition.unslicedImage];
                imageRep.size = NSMakeSize(CGImageGetWidth(rendition.unslicedImage), CGImageGetHeight(rendition.unslicedImage));

                NSString *const filename = [self filenameForAssetNamed:[self cleanupRenditionName:rendition.name] scale:rendition.scale presentationState:key.themeState];
                NSDictionary *desc = [self imageDescriptionWithName:rendition.name filename:filename representation:imageRep dataLength:rendition.srcData.length contentsData:^NSData *{
                    return [imageRep representationUsingType:NSBitmapImageFileTypePNG properties:@{NSImageInterlaced:@(NO)}];
                }];

                BOOL ignore = [filename containsString:@"ZZPackedAsset"] && self.ignorePackedAssets;

                if (!desc || ignore) {
                    loadedItemCount++;
                    return;
                }

                if (self.cancelled) return;

                [self.mutableImages addObject:desc];
            } else {
                NSLog(@"The rendition %@ doesn't have an image, It is probably an effect or material.", rendition.name);
            }

            loadedItemCount++;
        } @catch (NSException *exception) {
            NSLog(@"Exception while reading theme store: %@", exception);
        }
    }];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        callback();
    });
}

- (NSImage *)constrainImage:(NSImage *)image toSize:(NSSize)size
{
    if (image.size.width <= size.width && image.size.height <= size.height) return [image copy];
    
    CGFloat newWidth, newHeight = 0;
    double rw = image.size.width / size.width;
    double rh = image.size.height / size.height;
    
    if (rw > rh)
    {
        newHeight = MAX(roundl(image.size.height / rw), 1);
        newWidth = size.width;
    }
    else
    {
        newWidth = MAX(roundl(image.size.width / rh), 1);
        newHeight = size.height;
    }
    
    return [NSImage imageWithSize:NSMakeSize(newWidth, newHeight) flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        [image drawInRect:NSMakeRect(0, 0, newWidth, newHeight) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
        return YES;
    }];
}

- (BOOL)isProThemeStoreAtPath:(NSString *)path
{
    static const int proThemeTokenLength = 18;
    static const char proThemeToken[proThemeTokenLength] = { 0x50,0x72,0x6F,0x54,0x68,0x65,0x6D,0x65,0x44,0x65,0x66,0x69,0x6E,0x69,0x74,0x69,0x6F,0x6E };
    
    @try {
        NSData *catalogData = [[NSData alloc] initWithContentsOfFile:path options:NSDataReadingMappedAlways|NSDataReadingUncached error:nil];
        
        NSData *proThemeTokenData = [NSData dataWithBytes:(const void *)proThemeToken length:proThemeTokenLength];
        if ([catalogData rangeOfData:proThemeTokenData options:0 range:NSMakeRange(0, catalogData.length)].location != NSNotFound) {
            return YES;
        } else {
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"Unable to determine if catalog is pro, exception: %@", exception);
        return NO;
    }
}

- (NSArray <CUINamedImage *> *)imagesNamed:(NSString *)name
{
    NSMutableArray <CUINamedImage *> *images = [[NSMutableArray alloc] initWithCapacity:3];
    
    for (NSNumber *factor in @[@1,@2,@3]) {
        CUINamedImage *image = [self.catalog imageWithName:name scaleFactor:factor.doubleValue];
        if (!image || image.scale != factor.doubleValue) continue;
        
        [images addObject:image];
    }
    
    return images;
}

- (NSDictionary *)imageDescriptionWithName:(NSString *)name
                                  filename:(NSString *)filename
                            representation:(NSImageRep *)imageRep
                                 dataLength:(NSUInteger)length
                              contentsData:(NSData *(^)(void))contentsData
{
    if (_resourceConstrained) {
        return @{
                 kACSNameKey : name,
                 kACSFilenameKey: filename,
                 kACSImageRepKey: imageRep,
                 kACSCompressedSizeKey: [NSNumber numberWithUnsignedInteger:length],
                 };
    } else {
        NSData *pngData = contentsData();
        if (!pngData.length) {
            NSLog(@"Unable to get PNG data from rendition named %@", name);
            return nil;
        }
        
        NSImage *originalImage = [[NSImage alloc] initWithData:pngData];
        NSImage *thumbnail = [self constrainImage:originalImage toSize:self.thumbnailSize];
        
        return @{
                 kACSNameKey : name,
                 kACSImageKey : originalImage,
                 kACSThumbnailKey: thumbnail,
                 kACSFilenameKey: filename,
                 kACSContentsDataKey: pngData,
                 kACSCompressedSizeKey: [NSNumber numberWithUnsignedInteger:length],
                 kACSUncompressedSizeKey: [NSNumber numberWithUnsignedInteger:pngData.length],
                 };
    }
}

- (NSString *)cleanupRenditionName:(NSString *)name
{
    NSArray *components = [name.stringByDeletingPathExtension componentsSeparatedByString:@"@"];
    
    return components.firstObject;
}

- (NSString *)filenameForAssetNamed:(NSString *)name scale:(CGFloat)scale presentationState:(NSInteger)presentationState
{
    if (scale > 1.0) {
        if (presentationState != kCoreThemeStateNone) {
            return [NSString stringWithFormat:@"%@_%@@%.0fx.png", name, themeStateNameForThemeState(presentationState), scale];
        } else {
            return [NSString stringWithFormat:@"%@@%.0fx.png", name, scale];
        }
    } else {
        if (presentationState != kCoreThemeStateNone) {
            return [NSString stringWithFormat:@"%@_%@.png", name, themeStateNameForThemeState(presentationState)];
        } else {
            return [NSString stringWithFormat:@"%@.png", name];
        }
    }
}

- (NSString *)filenameForVectorAssetNamed:(NSString *)name renderingMode:(UIImageSymbolRenderingMode)renderingMode weight:(UIImageSymbolWeight)weight size:(UIImageSymbolScale)size {
    NSString *weightName;
    switch (weight) {
    case UIImageSymbolWeightUnspecified:
        weightName = @"unspecified";
        break;
    case UIImageSymbolWeightUltraLight:
        weightName = @"ultraLight";
        break;
    case UIImageSymbolWeightThin:
        weightName = @"thin";
        break;
    case UIImageSymbolWeightLight:
        weightName = @"light";
        break;
    case UIImageSymbolWeightRegular:
        weightName = @"regular";
        break;
    case UIImageSymbolWeightMedium:
        weightName = @"medium";
        break;
    case UIImageSymbolWeightSemibold:
        weightName = @"semibold";
        break;
    case UIImageSymbolWeightBold:
        weightName = @"bold";
        break;
    case UIImageSymbolWeightHeavy:
        weightName = @"heavy";
        break;
    case UIImageSymbolWeightBlack:
        weightName = @"black";
        break;
    }

    NSString *sizeName;
    switch (size) {
    case UIImageSymbolScaleDefault:
        sizeName = @"default";
        break;
    case UIImageSymbolScaleUnspecified:
        sizeName = @"unspecified";
        break;
    case UIImageSymbolScaleSmall:
        sizeName = @"small";
        break;
    case UIImageSymbolScaleMedium:
        sizeName = @"medium";
        break;
    case UIImageSymbolScaleLarge:
        sizeName = @"large";
        break;
    }

    NSString *renderingModeName;
    switch (renderingMode) {
    case UIImageSymbolRenderingModeAutomatic:
        renderingModeName = @"automatic";
        break;
    case UIImageSymbolRenderingModeTemplate:
        renderingModeName = @"template";
        break;
    case UIImageSymbolRenderingModeMulticolor:
        renderingModeName = @"multicolor";
        break;
    case UIImageSymbolRenderingModeHierarchical:
        renderingModeName = @"hierarchical";
        break;
    }
    return  [NSString stringWithFormat:@"%@_%@_%@_%@.svg", name, weightName, sizeName, renderingModeName];
}

- (BOOL)catalogHasRetinaContent
{
    if (!_computedCatalogHasRetinaContent) {
        for (NSString *name in self.catalog.allImageNames) {
            for (CUINamedImage *namedImage in [self imagesNamed:name]) {
                if (namedImage.scale > 1) {
                    _catalogHasRetinaContent = YES;
                    break;
                }
            }
            if (_catalogHasRetinaContent) break;
        }
        
        _computedCatalogHasRetinaContent = YES;
    }
    
    return _catalogHasRetinaContent;
}

@end
