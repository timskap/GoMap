//
//  PresetsDatabase.swift
//  Go Map!!
//
//  Created by Bryce Cogswell on 6/29/20.
//  Copyright © 2020 Bryce Cogswell. All rights reserved.
//

import CountryCoder
import Foundation

final class PresetsDatabase {
	static var shared = PresetsDatabase()
	class func reload() {
		// called when language changes
		shared = PresetsDatabase()
	}

	// these map a FeatureID to a feature
	let stdPresets: [String: PresetFeature] // only generic presets
	var nsiPresets: [String: PresetFeature] // only NSI presets
	// these map a tag key to a list of features that require that key
	let stdIndex: [String: [PresetFeature]] // generic preset index
	var nsiIndex: [String: [PresetFeature]] // generic+NSI index
	var nsiGeoJson: [String: GeoJSON] // geojson regions for NSI

	private class func DictionaryForFile(_ file: String?) -> Any? {
		guard let file = file else { return nil }
		let rootDir = Bundle.main.resourcePath!
		let rootPresetPath = rootDir + "/presets/" + file
		guard let rootPresetData = NSData(contentsOfFile: rootPresetPath) as Data? else { return nil }
		do {
			let dict = try JSONSerialization.jsonObject(with: rootPresetData, options: [])
			return dict
		} catch {}
		return nil
	}

	private class func Translate(_ orig: Any, _ translation: Any?) -> Any {
		guard let translation = translation else {
			return orig
		}
		let orig = orig as! [String: Any]
		let translation2 = translation as! [String: Any]

		// both are dictionaries, so recurse on each key/value pair
		var newDict = [String: Any]()
		for (key, obj) in orig {
			if key == "options" {
				newDict[key] = obj
				newDict["strings"] = translation2[key]
			} else {
				newDict[key] = Translate(obj, translation2[key])
			}
		}
		for (key, obj) in translation2 {
			// need to add things that don't exist in orig
			if newDict[key] == nil {
				newDict[key] = obj
			}
		}
		return newDict
	}

	let jsonAddressFormats: [Any] // address formats for different countries
	let jsonDefaults: [String: Any] // map a geometry to a set of features/categories
	let jsonCategories: [String: Any] // map a top-level category ("building") to a set of specific features ("building/retail")
	let jsonFields: [String: Any] // possible values for a preset key ("oneway=")

	let yesForLocale: String
	let noForLocale: String
	let unknownForLocale: String

	init() {
		// get translations for current language
		let presetLanguages =
			PresetLanguages() // don't need to save this, it doesn't get used again unless user changes the language
		let code = presetLanguages.preferredLanguageCode()
		let file = "translations/" + code + ".json"
		let trans = PresetsDatabase.DictionaryForFile(file) as! [String: [String: Any]]
		let jsonTranslation = (trans[code]?["presets"] as? [String: [String: Any]]) ?? [String: [String: Any]]()
		let yesNoDict =
			(jsonTranslation["fields"]?["internet_access"] as? [String: Any])?["options"] as? [String: String]
		yesForLocale = yesNoDict?["yes"] ?? "Yes"
		noForLocale = yesNoDict?["no"] ?? "No"
		unknownForLocale =
			(jsonTranslation["fields"]?["opening_hours"] as? [String: Any])?["placeholder"] as? String ??
			"???"

		// get presets files
		let jsonDefaultsPre = PresetsDatabase.DictionaryForFile("preset_defaults.json")!
		let jsonCategoriesPre = PresetsDatabase.DictionaryForFile("preset_categories.json")!
		let jsonFieldsPre = PresetsDatabase.DictionaryForFile("fields.json")!
		jsonDefaults = (PresetsDatabase.Translate(jsonDefaultsPre, jsonTranslation["defaults"]) as? [String: Any])!
		jsonCategories = (PresetsDatabase
			.Translate(jsonCategoriesPre, jsonTranslation["categories"]) as? [String: Any])!
		jsonFields = (PresetsDatabase.Translate(jsonFieldsPre, jsonTranslation["fields"]) as? [String: Any])!

		// address formats
		jsonAddressFormats = PresetsDatabase.DictionaryForFile("address_formats.json") as! [Any]

		// initialize presets and index them
		var jsonPresetsDict = PresetsDatabase.DictionaryForFile("presets.json")!
		jsonPresetsDict = PresetsDatabase.Translate(jsonPresetsDict, jsonTranslation["presets"])
		stdPresets = PresetsDatabase.featureDictForJsonDict(jsonPresetsDict as! [String: [String: Any]], isNSI: false)
		stdIndex = PresetsDatabase.buildTagIndex([stdPresets], basePresets: stdPresets)

		// name suggestion index
		nsiPresets = [String: PresetFeature]()
		nsiIndex = stdIndex
		nsiGeoJson = [String: GeoJSON]()

		DispatchQueue.global(qos: .userInitiated).async {
			let jsonNsiPresetsDict = PresetsDatabase.DictionaryForFile("nsi_presets.json")
			let nsiPresets2 = PresetsDatabase.featureDictForJsonDict(
				jsonNsiPresetsDict as! [String: [String: Any]],
				isNSI: true)
			let nsiIndex2 = PresetsDatabase.buildTagIndex([self.stdPresets, nsiPresets2], basePresets: self.stdPresets)
			DispatchQueue.main.async {
				self.nsiPresets = nsiPresets2
				self.nsiIndex = nsiIndex2

#if DEBUG
				// verify all fields can be read
				for (field, info) in self.jsonFields {
					var geometry = GEOMETRY.LINE
					if let info = info as? [String: Any],
					   let geom = info["geometry"] as? [String]
					{
						geometry = GEOMETRY(rawValue: geom[0])!
					}
					_ = self.groupForField(fieldName: field,
					                       objectTags: [:],
					                       geometry: geometry,
					                       ignore: [],
					                       update: nil)
				}
#endif
			}
		}

		DispatchQueue.global(qos: .userInitiated).async {
			if let json = Self.DictionaryForFile("nsi_geojson.json"),
			   let dict = json as? [String: Any?],
			   let features = dict["features"] as? [Any]
			{
				var featureDict = [String: GeoJSON]()
				for feature2 in features {
					guard let feature = feature2 as? [String: Any?] else { continue }
					if feature["type"] as? String == "Feature",
					   let name = feature["id"] as? String,
					   let geomDict = feature["geometry"] as? [String: Any?],
					   let geojson = GeoJSON(geometry: geomDict)
					{
						featureDict[name] = geojson
					}
				}
				DispatchQueue.main.async {
					self.nsiGeoJson = featureDict
				}
			}
		}
	}

	// OSM TagInfo database in the cloud: contains either a group or an array of values
	var taginfoCache = [String: [String]]()

	// initialize presets database
	private class func featureDictForJsonDict(_ dict: [String: [String: Any]], isNSI: Bool) -> [String: PresetFeature] {
		let presetDict = isNSI ? dict["presets"] as! [String: [String: Any]] : dict
		var presets = [String: PresetFeature]()
		presets.reserveCapacity(presetDict.count)
		for (name, values) in presetDict {
			presets[name] = PresetFeature(withID: name, jsonDict: values, isNSI: isNSI)
		}
		return presets
	}

	/// basePresets is always the regular presets
	/// inputList is either regular presets, or both presets and NSI
	private class func buildTagIndex(_ inputList: [[String: PresetFeature]],
	                                 basePresets: [String: PresetFeature]) -> [String: [PresetFeature]]
	{
		// keys contains all tag keys that have an associated preset
		var keys: [String: Int] = [:]
		for (featureID, _) in basePresets {
			var key = featureID
			if let range = key.range(of: "/") {
				key = String(key.prefix(upTo: range.lowerBound))
			}
			keys[key] = (keys[key] ?? 0) + 1
		}
		var tagIndex: [String: [PresetFeature]] = [:]
		for list in inputList {
			for (_, feature) in list {
				var added = false
				for key in feature.tags.keys {
					if keys[key] != nil {
						if tagIndex[key]?.append(feature) == nil {
							tagIndex[key] = [feature]
						}
						added = true
					}
				}
				if !added {
					if tagIndex[""]?.append(feature) == nil {
						tagIndex[""] = [feature]
					}
				}
			}
		}
		return tagIndex
	}

	// enumerate contents of database
	func enumeratePresetsUsingBlock(_ block: (_ feature: PresetFeature) -> Void) {
		for (_, v) in stdPresets {
			block(v)
		}
	}

	func enumeratePresetsAndNsiUsingBlock(_ block: (_ feature: PresetFeature) -> Void) {
		for v in stdPresets.values {
			block(v)
		}
		for v in nsiPresets.values {
			block(v)
		}
	}

	// go up the feature tree and return the first instance of the requested field value
	private class func inheritedFieldForPresetsDict(_ presetDict: [String: PresetFeature],
	                                                featureID: String?,
	                                                field fieldGetter: @escaping (_ feature: PresetFeature) -> Any?)
		-> Any?
	{
		var featureID = featureID
		while featureID != nil {
			if let feature = presetDict[featureID!],
			   let field = fieldGetter(feature)
			{
				return field
			}
			featureID = PresetFeature.parentIDofID(featureID!)
		}
		return nil
	}

	func inheritedValueOfFeature(_ featureID: String?,
	                             fieldGetter: @escaping (_ feature: PresetFeature) -> Any?)
		-> Any?
	{
		// This is currently never used for NSI entries, so we can ignore nsiPresets
		return PresetsDatabase.inheritedFieldForPresetsDict(stdPresets, featureID: featureID, field: fieldGetter)
	}

	func presetFeatureForFeatureID(_ featureID: String) -> PresetFeature? {
		return stdPresets[featureID] ?? nsiPresets[featureID]
	}

	func matchObjectTagsToFeature(_ objectTags: [String: String]?,
	                              geometry: GEOMETRY,
	                              includeNSI: Bool) -> PresetFeature?
	{
		guard let objectTags = objectTags else { return nil }

		var bestFeature: PresetFeature?
		var bestScore = 0.0

		let index = includeNSI ? nsiIndex : stdIndex
		let keys = objectTags.keys + [""]
		for key in keys {
			if let list = index[key] {
				for feature in list {
					let score = feature.matchObjectTagsScore(objectTags, geometry: geometry)
					if score > bestScore {
						bestScore = score
						bestFeature = feature
					}
				}
			}
		}
		return bestFeature
	}

	func featuresMatchingSearchText(_ searchText: String?, geometry: GEOMETRY,
	                                latLon: LatLon) -> [(PresetFeature, Int)]
	{
		let latLonAsPoint = CGPoint(OSMPoint(latLon))
		var list = [(PresetFeature, Int)]()
		enumeratePresetsAndNsiUsingBlock { feature in
			guard feature.searchable,
			      let score = feature.matchesSearchText(searchText, geometry: geometry)
			else {
				return
			}
			if let loc = feature.locationSet,
			   let includes = loc["include"]
			{
				let okay = includes.contains(where: { include in

					if let include = include as? String {
						if include == "001" {
							return true
						} else if include.hasSuffix(".geojson") {
							if let geojson = self.nsiGeoJson[include],
							   geojson.contains(latLonAsPoint)
							{
								print("accepting \(include)")
								return true
							}
							return false
						} else {
							guard let bezier = CountryCoder.shared?.geometryForCountryCode(include) else {
								print("unknown code: \(feature.name ?? "?"): \(include)")
								return false
							}
							if bezier.contains(latLonAsPoint) {
								print("accepting \(include)")
								return true
							}
							return false
						}
					} else if let numbers = include as? [NSNumber],
					          (2...3).contains(numbers.count)
					{
						// lat, lon, radius
						let lon = numbers[0].doubleValue
						let lat = numbers[1].doubleValue
						let radius = numbers.count > 2 ? numbers[2].doubleValue : 25000.0
						let dist = GreatCircleDistance(LatLon(lon: lon, lat: lat),
						                               latLon)
						return dist <= radius
					}
					print("unknown include: \(feature.name ?? "?"): \(include)")
					return false
				})
				if !okay {
					return
				}
			}
			list.append((feature, score))
		}
		return list
	}
}
